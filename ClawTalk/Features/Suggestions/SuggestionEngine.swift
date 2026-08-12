import Foundation
import Observation

/// 主动建议引擎：依据真实本地数据（健康 / 习惯 / 记账 / 语音日记 / 提醒）生成建议。
///
/// 诚实原则：
/// - 数据不足不硬生成：健康权限未开或当日无步数 → 无健康建议；
///   本周或上周无真实记账记录 → 不比较金额；无未沉淀灵感 → 无记忆建议；
///   明天提醒不足 3 条 → 无效率建议。
/// - 每条建议正文都带真实数字（步数 / 金额 / 条数），不编造。
@MainActor
struct SuggestionEngine {

    /// 健康建议：今日步数低于该值视为「步数偏少」。
    static let lowStepThreshold = 3000
    /// 连续几天步数偏低触发高优先级建议。
    static let consecutiveLowStepDays = 3
    /// 明天提醒达到该数量才建议预告。
    static let tomorrowReminderThreshold = 3
    /// 单次生成上限（避免一次刷出一堆建议）。
    static let maxSuggestionsPerRun = 8
    /// 习惯建议最多条数（只提示最值得保住连续天数的）。
    static let maxHabitSuggestions = 5

    private let healthViewModel: HealthViewModel?
    private let habitStore: HabitStore?
    private let expenseStore: ExpenseStore?
    private let diaryViewModel: VoiceDiaryViewModel?
    private let careReminderStore: CareReminderStore?
    private let now: Date

    init(
        healthViewModel: HealthViewModel? = nil,
        habitStore: HabitStore? = nil,
        expenseStore: ExpenseStore? = nil,
        diaryViewModel: VoiceDiaryViewModel? = nil,
        careReminderStore: CareReminderStore? = nil,
        now: Date = Date()
    ) {
        self.healthViewModel = healthViewModel
        self.habitStore = habitStore
        self.expenseStore = expenseStore
        self.diaryViewModel = diaryViewModel
        self.careReminderStore = careReminderStore
        self.now = now
    }

    // MARK: - 生成

    /// 生成今日建议（去重 + 按优先级截断）。任一数据源未接入 / 数据不足时跳过对应规则。
    func generate() async -> [Suggestion] {
        var candidates: [Suggestion] = []

        await appendHealthSuggestions(to: &candidates)
        appendHabitSuggestions(to: &candidates)
        appendExpenseSuggestions(to: &candidates)
        appendMemorySuggestions(to: &candidates)
        appendReminderSuggestions(to: &candidates)

        // 防御性去重（不同规则理论上不会撞，这里兜底）
        var seen = Set<String>()
        let deduped = candidates.filter { seen.insert($0.dedupeKey).inserted }

        // 高优先级在前，同优先级按生成时间倒序
        let sorted = deduped.sorted {
            if $0.priority.rank != $1.priority.rank {
                return $0.priority.rank < $1.priority.rank
            }
            return $0.createdAt > $1.createdAt
        }
        return Array(sorted.prefix(Self.maxSuggestionsPerRun))
    }

    // MARK: - 健康：今日步数偏低 / 连续偏低升级

    private func appendHealthSuggestions(to candidates: inout [Suggestion]) async {
        guard let healthViewModel else { return }
        // 重新读取最新健康数据（与健康卡下拉刷新同款）
        await healthViewModel.load()
        guard healthViewModel.accessState == .authorized,
              let todaySteps = healthViewModel.todaySteps else { return }

        guard todaySteps < Self.lowStepThreshold else { return }

        // HealthViewModel.dailySteps 为近 7 天自然日升序、最后一项为今天，
        // 倒序遍历即为「以今天为终点」的连续天数。
        let lowDays = Self.consecutiveLowDays(
            in: healthViewModel.dailySteps,
            below: Self.lowStepThreshold
        )
        if lowDays >= Self.consecutiveLowStepDays {
            candidates.append(Suggestion(
                type: .health,
                priority: .high,
                title: "连续 \(lowDays) 天步数偏少",
                body: "最近 \(lowDays) 天每天都没到 \(Self.lowStepThreshold) 步（今天 \(todaySteps) 步），起来活动一下吧",
                action: ["去健康"]
            ))
        } else {
            candidates.append(Suggestion(
                type: .health,
                priority: .medium,
                title: "今天步数偏少",
                body: "今天走了 \(todaySteps) 步，还不到 \(Self.lowStepThreshold) 步，起来活动一下",
                action: ["去健康"]
            ))
        }
    }

    /// 以今天为终点，连续多少天步数低于阈值（只统计有真实逐日数据的日子）。
    private static func consecutiveLowDays(
        in dailySteps: [HealthViewModel.DaySteps],
        below threshold: Int
    ) -> Int {
        var count = 0
        for day in dailySteps.reversed() {
            guard day.steps < threshold else { break }
            count += 1
        }
        return count
    }

    // MARK: - 习惯：应打卡未打（下午）

    private func appendHabitSuggestions(to candidates: inout [Suggestion]) {
        guard let habitStore else { return }
        let hour = Calendar.current.component(.hour, from: now)
        // 只在下午提醒（上午用户可能还没开始打卡，避免打扰）
        guard hour >= 12 else { return }

        let dueUnchecked = habitStore.habits
            .filter { $0.isDue(on: now) && !$0.isChecked(on: now) }
            .sorted { $0.streak > $1.streak }
            .prefix(Self.maxHabitSuggestions)

        for habit in dueUnchecked {
            // 连续天数越久越值得保住，优先级相应提高
            let priority: SuggestionPriority = habit.streak >= 3 ? .medium : .low
            let streakText = habit.streak > 0 ? "，已连续 \(habit.streak) 天" : ""
            candidates.append(Suggestion(
                type: .habit,
                priority: priority,
                title: "「\(habit.name)」还没打卡",
                body: "今天的「\(habit.name)」还没打卡\(streakText)，别断了",
                action: ["去打卡"]
            ))
        }
    }

    // MARK: - 记账：本周支出超上周 / 连续超支

    private func appendExpenseSuggestions(to candidates: inout [Suggestion]) {
        guard let expenseStore else { return }
        let calendar = Calendar.current
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart),
              let lastWeekEnd = calendar.date(byAdding: .day, value: 7, to: thisWeekStart) else { return }

        let expenses = expenseStore.entries.filter { $0.type == .expense }
        let thisWeekEntries = expenses.filter { $0.date >= thisWeekStart && $0.date <= now }
        let lastWeekEntries = expenses.filter { $0.date >= lastWeekStart && $0.date < lastWeekEnd }

        // 诚实：本周或上周没有真实记账记录就不比较（0 条可能是没记账，不是真花 0 元）
        guard !thisWeekEntries.isEmpty, !lastWeekEntries.isEmpty else { return }

        let thisWeekTotal = thisWeekEntries.reduce(0.0) { $0 + $1.amount }
        let lastWeekTotal = lastWeekEntries.reduce(0.0) { $0 + $1.amount }
        guard thisWeekTotal > lastWeekTotal else { return }

        if Self.isConsecutiveOverspend(expenses: expenses, thisWeekStart: thisWeekStart, now: now) {
            candidates.append(Suggestion(
                type: .finance,
                priority: .high,
                title: "连续超支，注意控制",
                body: "已连续 3 周支出超过上一周，本周已花 \(Self.expenseText(thisWeekTotal)) 元，上周 \(Self.expenseText(lastWeekTotal)) 元",
                action: ["查看记账"]
            ))
        } else {
            let diff = thisWeekTotal - lastWeekTotal
            candidates.append(Suggestion(
                type: .finance,
                priority: .medium,
                title: "本周支出比上周高",
                body: "本周支出 \(Self.expenseText(thisWeekTotal)) 元，比上周同期的 \(Self.expenseText(lastWeekTotal)) 元多 \(Self.expenseText(diff)) 元",
                action: ["查看记账"]
            ))
        }
    }

    /// 连续超支判定：本周起往前 4 个自然周（含本周）都有真实记账记录，且支出逐周递增。
    private static func isConsecutiveOverspend(
        expenses: [ExpenseEntry],
        thisWeekStart: Date,
        now: Date
    ) -> Bool {
        let calendar = Calendar.current
        var weeklyTotals: [Double] = []
        for offset in stride(from: -3, through: 0, by: 1) {
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: offset, to: thisWeekStart),
                  let nextWeekStart = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return false }
            let weekEntries = expenses.filter { entry in
                if offset == 0 {
                    return entry.date >= weekStart && entry.date <= now
                }
                return entry.date >= weekStart && entry.date < nextWeekStart
            }
            // 某一周没有真实记账记录，无法证明连续超支
            guard !weekEntries.isEmpty else { return false }
            weeklyTotals.append(weekEntries.reduce(0.0) { $0 + $1.amount })
        }
        guard weeklyTotals.count == 4 else { return false }
        // 从最早一周到本周逐周递增 = 连续 3 次「超上一周」
        return weeklyTotals[1] > weeklyTotals[0]
            && weeklyTotals[2] > weeklyTotals[1]
            && weeklyTotals[3] > weeklyTotals[2]
    }

    /// 金额展示：整元不带小数，否则保留 1 位。
    private static func expenseText(_ amount: Double) -> String {
        if abs(amount - amount.rounded()) < 0.005 {
            return String(format: "%.0f", amount)
        }
        return String(format: "%.1f", amount)
    }

    // MARK: - 记忆：有新灵感未沉淀

    private func appendMemorySuggestions(to candidates: inout [Suggestion]) {
        guard let diaryViewModel else { return }
        let unsyncedInspirations = diaryViewModel.entries
            .filter { $0.category == .inspiration && $0.linkedToMemory != true }
            .sorted { $0.date > $1.date }
        guard let latest = unsyncedInspirations.first else { return }

        let snippet = Self.snippet(of: latest.text)
        let body = unsyncedInspirations.count > 1
            ? "有 \(unsyncedInspirations.count) 条灵感还没记进记忆，最新一条「\(snippet)」"
            : "「\(snippet)」这个想法还没记进记忆"
        candidates.append(Suggestion(
            type: .memory,
            priority: .medium,
            title: "有个想法可以记下来吗",
            body: body,
            action: ["去记忆"]
        ))
    }

    /// 摘要：截取开头若干字（避免卡片被长文本撑爆）。
    private static func snippet(of text: String, limit: Int = 18) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    // MARK: - 提醒：明天提醒多 → 今晚预告

    private func appendReminderSuggestions(to candidates: inout [Suggestion]) {
        guard let careReminderStore else { return }
        let hour = Calendar.current.component(.hour, from: now)
        // 只在晚上预告（18 点后）
        guard hour >= 18 else { return }

        let tomorrowCount = careReminderStore.reminders.filter { reminder in
            guard reminder.enabled,
                  let fireDate = careReminderStore.nextFireDate(for: reminder) else { return false }
            return Calendar.current.isDateInTomorrow(fireDate)
        }.count
        guard tomorrowCount >= Self.tomorrowReminderThreshold else { return }

        candidates.append(Suggestion(
            type: .efficiency,
            priority: .low,
            title: "明天有 \(tomorrowCount) 条提醒",
            body: "明天有 \(tomorrowCount) 条提醒，今晚提前看一眼安排",
            action: ["查看提醒"]
        ))
    }
}

/// 建议存储：UserDefaults JSON 持久化 + 每日一次生成 + 高优先级本地通知。
///
/// 触发时机（由视图接线）：
/// - 主页「主动建议」卡 .task / 建议列表 .task / 下拉刷新 → 调 refresh()；
/// - 同一天只生成一次（lastSuggestionDate 记录），再次触发只重读本地已存建议；
/// - 高优先级新建议生成后发本地通知（NotificationCapability），可在列表页关闭。
@Observable
@MainActor
final class SuggestionStore {

    /// 未读建议（高优先级在前，同优先级按生成时间倒序）
    private(set) var suggestions: [Suggestion] = []
    private(set) var isLoading = false
    /// 高优先级建议通知开关（UserDefaults 持久化，默认开）
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: notifyKey) }
    }

    private let engine: SuggestionEngine
    private let defaults = UserDefaults.standard
    private let storageKey = "clawtalk_suggestions_v1"
    private let lastDateKey = "clawtalk_suggestions_last_generated_date"
    private let ignoredKey = "clawtalk_suggestions_ignored_keys"
    private let notifyKey = "clawtalk_suggestions_notify_enabled"
    /// 建议保留天数（超出即清理，避免残留过期未读）。
    private static let storedKeepDays = 7
    /// 忽略后同内容多少天内不再生成。
    private static let ignoredKeepDays = 7
    /// 忽略键（dedupeKey）-> 忽略时间。
    private var ignoredKeys: [String: Date] = [:]

    init(
        settingsStore: SettingsStore? = nil,
        healthViewModel: HealthViewModel? = nil,
        habitStore: HabitStore? = nil,
        expenseStore: ExpenseStore? = nil,
        diaryViewModel: VoiceDiaryViewModel? = nil,
        careReminderStore: CareReminderStore? = nil
    ) {
        let settings = settingsStore ?? SettingsStore()
        self.engine = SuggestionEngine(
            healthViewModel: healthViewModel,
            habitStore: habitStore,
            expenseStore: expenseStore,
            diaryViewModel: diaryViewModel ?? VoiceDiaryViewModel(settingsStore: settings),
            careReminderStore: careReminderStore
        )
        self.notificationsEnabled = defaults.object(forKey: notifyKey) as? Bool ?? true
        load()
    }

    // MARK: - 派生

    /// 未读条数（主页卡片角标）。
    var unreadCount: Int { suggestions.count }

    /// 最新一条建议（主页卡片摘要；无则 nil，展示诚实空态）。
    var latestSuggestion: Suggestion? { suggestions.first }

    // MARK: - 刷新 / 生成

    /// 刷新建议：同一天已生成过则只重读本地存储；否则执行每日一次生成。
    func refresh() async {
        guard !hasGeneratedToday else {
            load()
            return
        }
        isLoading = true
        defer { isLoading = false }

        let fresh = await engine.generate()
        merge(fresh)
        defaults.set(Self.dayFormatter.string(from: Date()), forKey: lastDateKey)
        await notifyHighPriority(of: fresh)
    }

    // MARK: - 操作

    /// 标为已读（从未读列表移除）。
    func markRead(id: UUID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[index].read = true
        suggestions.remove(at: index)
        persist()
    }

    /// 忽略（同内容几天内不再生成）。
    func ignore(id: UUID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        ignoredKeys[suggestions[index].dedupeKey] = Date()
        pruneIgnoredKeys()
        suggestions.remove(at: index)
        persist()
    }

    /// 全部标为已读。
    func markAllRead() {
        suggestions = []
        persist()
    }

    // MARK: - 合并 / 持久化

    private func merge(_ fresh: [Suggestion]) {
        // 忽略键过滤：同内容近期忽略过的不再生成
        let candidates = fresh.filter { ignoredKeys[$0.dedupeKey] == nil }
        // 已存未读中仍有效的建议：保留原 id / 时间（去重），避免列表抖动
        var kept: [Suggestion] = []
        for candidate in candidates {
            if let existing = suggestions.first(where: { $0.dedupeKey == candidate.dedupeKey }) {
                kept.append(existing)
            } else {
                kept.append(candidate)
            }
        }
        suggestions = Self.sorted(kept)
            .filter { !$0.read }
            .filter { Date().timeIntervalSince($0.createdAt) < TimeInterval(Self.storedKeepDays * 86400) }
        persist()
    }

    private func load() {
        if let data = defaults.data(forKey: ignoredKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            ignoredKeys = decoded
            pruneIgnoredKeys()
        }
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Suggestion].self, from: data) else {
            suggestions = []
            return
        }
        suggestions = Self.sorted(decoded.filter {
            !$0.read
                && Date().timeIntervalSince($0.createdAt) < TimeInterval(Self.storedKeepDays * 86400)
        })
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(suggestions) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func pruneIgnoredKeys() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(Self.ignoredKeepDays * 86400))
        let pruned = ignoredKeys.filter { $0.value > cutoff }
        if pruned.count != ignoredKeys.count {
            ignoredKeys = pruned
            if let data = try? JSONEncoder().encode(ignoredKeys) {
                defaults.set(data, forKey: ignoredKey)
            }
        }
    }

    private var hasGeneratedToday: Bool {
        defaults.string(forKey: lastDateKey) == Self.dayFormatter.string(from: Date())
    }

    private static func sorted(_ items: [Suggestion]) -> [Suggestion] {
        items.sorted {
            if $0.priority.rank != $1.priority.rank {
                return $0.priority.rank < $1.priority.rank
            }
            return $0.createdAt > $1.createdAt
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - 通知

    /// 高优先级建议生成后发本地通知；开关关闭或权限拒绝时静默跳过（不影响本地列表）。
    private func notifyHighPriority(of fresh: [Suggestion]) async {
        guard notificationsEnabled else { return }
        for suggestion in fresh where suggestion.priority == .high {
            try? await NotificationCapability.notify(
                title: suggestion.title,
                body: suggestion.body,
                sound: "default",
                priority: "high"
            )
        }
    }
}
