import Foundation
import Observation

/// 语音打卡结果：成功 / 今天已打过 / 没找到对应习惯（诚实反馈，不静默）。
enum HabitVoiceCheckResult: Equatable {
    case checked(habitID: String, name: String)
    case alreadyChecked(habitID: String, name: String)
    case notFound(name: String)
}

/// 新增习惯时「重复日」的快捷预设（alert 里选择；编辑页可自由勾选周几）。
enum HabitRepeatPreset: String, CaseIterable, Identifiable {
    case everyDay = "每天"
    case workday = "工作日（周一至周五）"
    case weekend = "周末"
    case monday = "仅周一"
    case tuesday = "仅周二"
    case wednesday = "仅周三"
    case thursday = "仅周四"
    case friday = "仅周五"
    case saturday = "仅周六"
    case sunday = "仅周日"

    var id: String { rawValue }

    /// 对应 Calendar weekday 集合（1=周日 … 7=周六，周一=2）。
    var weekdays: [Int] {
        switch self {
        case .everyDay: return Array(1...7)
        case .workday: return [2, 3, 4, 5, 6]
        case .weekend: return [1, 7]
        case .monday: return [2]
        case .tuesday: return [3]
        case .wednesday: return [4]
        case .thursday: return [5]
        case .friday: return [6]
        case .saturday: return [7]
        case .sunday: return [1]
        }
    }
}

/// 习惯本地存储：UserDefaults JSON（与 CareReminderStore/ExpenseStore 同款）。
///
/// 职责：
/// - 增删改查 + 今日打卡 + 连续天数（模型内计算，跨月/跨年正确）；
/// - 与 CareReminderStore 联动：建习惯可选同步一条「每天同一时间」的提醒
///   （只读调用 CareReminderStore.add / update / delete，不重复造通知）；
/// - 语音打卡：「喝水打卡」→ 自动匹配习惯并打卡；匹配不到诚实报「没找到叫 X 的习惯」。
@Observable
@MainActor
final class HabitStore {

    private(set) var habits: [Habit] = []
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "习惯打卡", errorMessage)
            }
        }
    }

    private let storageKey = "clawtalk_habits_v1"
    /// 提醒联动数据源；未注入时默认自建（提醒数据都在 UserDefaults，多实例共享同一数据）
    private let careReminderStore: CareReminderStore

    init(careReminderStore: CareReminderStore? = nil) {
        self.careReminderStore = careReminderStore ?? CareReminderStore()
        load()
    }

    // MARK: - 查询

    func habit(id: String) -> Habit? {
        habits.first { $0.id == id }
    }

    /// 今日应打卡的习惯数（repeatDays 含今天的 weekday）。
    var todayDueCount: Int {
        habits.filter { $0.isDue(on: Date()) }.count
    }

    /// 今日已打卡的习惯数（只统计今日应打卡的，休息日不计）。
    var todayCompletedCount: Int {
        habits.filter { $0.isDue(on: Date()) && $0.isChecked(on: Date()) }.count
    }

    /// 所有习惯当前连续天数的最大值（主页卡片「最长连续」）。
    var longestStreak: Int {
        habits.map(\.streak).max() ?? 0
    }

    // MARK: - 增删改

    /// 新建习惯；`linkDailyReminder` 开启时同步一条 CareReminderStore 每日提醒。
    @discardableResult
    func addHabit(
        name: String,
        icon: String,
        repeatDays: [Int],
        targetPerDay: Int? = nil,
        linkDailyReminder: Bool = false,
        reminderTime: Date? = nil
    ) -> Habit? {
        let reminderTime = reminderTime ?? Self.defaultReminderTime
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var habit = Habit(name: trimmed, icon: icon, repeatDays: repeatDays, targetPerDay: targetPerDay)
        if linkDailyReminder {
            habit.linkedReminderID = createLinkedReminder(for: habit, time: reminderTime)
        }
        habits.append(habit)
        persist()
        return habit
    }

    /// 整条更新（按 id 替换；联动提醒存在时同步标题）。
    func update(_ habit: Habit) {
        guard let index = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[index] = habit
        syncLinkedReminderTitle(for: habit)
        persist()
    }

    /// 删除习惯；联动提醒一并删除（不残留孤儿通知）。
    func delete(id: String) {
        guard let habit = habits.first(where: { $0.id == id }) else { return }
        if let reminderID = habit.linkedReminderID {
            careReminderStore.delete(id: reminderID)
        }
        habits.removeAll { $0.id == id }
        persist()
    }

    /// 今日打卡：已打过返回 false（不覆盖、不重复计数），成功返回 true。
    @discardableResult
    func checkIn(id: String, on date: Date = Date()) -> Bool {
        guard let index = habits.firstIndex(where: { $0.id == id }) else { return false }
        let key = Habit.dateKey(for: date)
        guard habits[index].checkIns[key] == nil else { return false }
        habits[index].checkIns[key] = date
        persist()
        return true
    }

    /// 切换「同步每日提醒」：开 → 创建/更新时间；关 → 删除提醒并解除关联。
    func setLinkedReminder(_ enabled: Bool, for habitID: String, time: Date? = nil) {
        guard let index = habits.firstIndex(where: { $0.id == habitID }) else { return }
        var habit = habits[index]
        let time = time ?? Self.defaultReminderTime

        if enabled {
            if let reminderID = habit.linkedReminderID {
                // 已有关联：只更新时间
                if let reminderIndex = careReminderStore.reminders.firstIndex(where: { $0.id == reminderID }) {
                    var reminder = careReminderStore.reminders[reminderIndex]
                    reminder.time = time
                    careReminderStore.update(reminder)
                }
            } else {
                habit.linkedReminderID = createLinkedReminder(for: habit, time: time)
            }
        } else if let reminderID = habit.linkedReminderID {
            careReminderStore.delete(id: reminderID)
            habit.linkedReminderID = nil
        }

        habits[index] = habit
        persist()
    }

    /// 联动提醒当前时间（编辑页预填；未联动返回 nil）。
    func linkedReminderTime(for habitID: String) -> Date? {
        guard let habit = habit(id: habitID),
              let reminderID = habit.linkedReminderID,
              let reminder = careReminderStore.reminders.first(where: { $0.id == reminderID }) else {
            return nil
        }
        return reminder.time
    }

    /// 从 UserDefaults 重新读取（主页卡片返回时刷新摘要）。
    func reload() {
        load()
    }

    // MARK: - 语音打卡

    /// 语音文本打卡：「喝水打卡」→ 自动匹配习惯并打卡。
    /// - 匹配到且今日未打卡 → .checked
    /// - 匹配到但今日已打卡 → .alreadyChecked（诚实提示，不重复记）
    /// - 匹配不到 → .notFound(name:)（页面提示「没找到叫 X 的习惯」）
    @discardableResult
    func checkInByVoice(text: String, on date: Date = Date()) -> HabitVoiceCheckResult {
        let candidate = Self.extractHabitName(from: text)
        guard !candidate.isEmpty else { return .notFound(name: text) }
        guard let habit = Self.matchHabit(named: candidate, in: habits) else {
            return .notFound(name: candidate)
        }
        guard !habit.isChecked(on: date) else {
            return .alreadyChecked(habitID: habit.id, name: habit.name)
        }
        if checkIn(id: habit.id, on: date) {
            return .checked(habitID: habit.id, name: habit.name)
        }
        return .notFound(name: candidate)
    }

    /// 从「喝水打卡」「打卡喝水」「今天喝口水打个卡」等语音文本提取习惯名。
    private static func extractHabitName(from text: String) -> String {
        var result = text
        // 去掉标点
        let punctuation = CharacterSet(charactersIn: "，。！？、,.!?；;：:·")
        result = result.components(separatedBy: punctuation).joined()
        // 去掉「打卡」动作词
        result = result.replacingOccurrences(of: "打卡", with: "")
        // 去掉语气/助词（可叠加）
        for filler in ["帮我", "给我", "今天", "记得", "要", "去", "的", "了", "一下", "个", "把", "给"] {
            result = result.replacingOccurrences(of: filler, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按候选名匹配习惯：完全一致 > 包含关系（取名字最长者，避免短词误匹配）。
    private static func matchHabit(named candidate: String, in habits: [Habit]) -> Habit? {
        let normalized = candidate.replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        if let exact = habits.first(where: { $0.name == normalized }) {
            return exact
        }

        let containing = habits.filter { habit in
            let name = habit.name.replacingOccurrences(of: " ", with: "")
            guard !name.isEmpty else { return false }
            return name.contains(normalized) || normalized.contains(name)
        }
        return containing.max { $0.name.count < $1.name.count }
    }

    // MARK: - CareReminderStore 联动（只读调用，不重复造通知）

    /// 默认提醒时间：今晚 20:00（用户可在新增/编辑时改）。
    static var defaultReminderTime: Date {
        Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()
    }

    /// 创建一条「每天同一时间」的 CareReminder 并返回其 id。
    private func createLinkedReminder(for habit: Habit, time: Date) -> String? {
        let reminder = CareReminder(
            title: habit.name,
            time: time,
            category: .custom,
            repeatType: .daily,
            enabled: true,
            createdAt: habit.createdAt
        )
        return careReminderStore.add(reminder).id
    }

    /// 习惯改名后同步联动提醒标题（保证列表/通知文案一致）。
    private func syncLinkedReminderTitle(for habit: Habit) {
        guard let reminderID = habit.linkedReminderID,
              let index = careReminderStore.reminders.firstIndex(where: { $0.id == reminderID }) else {
            return
        }
        var reminder = careReminderStore.reminders[index]
        reminder.title = habit.name
        careReminderStore.update(reminder)
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Habit].self, from: data)
        else {
            habits = []
            return
        }
        habits = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(habits) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
