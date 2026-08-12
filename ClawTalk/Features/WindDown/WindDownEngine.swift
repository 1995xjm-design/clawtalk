import Foundation
import EventKit

/// 「睡前陪伴」播报引擎：睡前说晚安时聚合
/// 今日总结（今日日记条数 / 今日已到点提醒数 / 习惯打卡 X/Y）+
/// 明日预告（明日提醒 / 明日待办 / 明日日程）+ 晚安语，
/// 生成一段温柔的自然语言文案，供 TTS 一键朗读。
///
/// 诚实原则（不造假）：
/// - 每个数据源独立读取；未注入 / 未授权 / 失败时降级跳过，并在 `skippedNotes` 标注原因。
/// - 明日系统待办 / 明日日程只在已授权时读取（不主动弹权限框），未授权诚实跳过。
/// - CareReminderStore 没有「已完成」字段，故「完成提醒数」以
///   「今日已到点（今天的触发时刻已过）的提醒」作为诚实口径。
///
/// 使用（主智能体接线）：
/// ```swift
/// let engine = WindDownEngine(
///     careStore: careStore,
///     diaryViewModel: diaryViewModel, // 可选
///     habitStore: habitStore          // 可选
/// )
/// let content = await engine.build()
/// ```
@MainActor
struct WindDownEngine {

    /// 播报条目（提醒 / 待办 / 日程共用展示结构）。
    struct BriefItem: Identifiable, Equatable {
        let id: String
        let title: String
        /// 触发 / 截止 / 开始时间；无时间信息时为 nil
        let time: Date?
        /// 附加说明（提醒类别 / 待办列表名 / 日程地点）
        let detail: String?

        var timeText: String? {
            guard let time else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: time)
        }
    }

    /// 被跳过的数据源说明（页面如实展示）。
    struct SkipNote: Equatable, Identifiable {
        let section: String
        let message: String
        var id: String { section }
    }

    /// 一次聚合的快照（睡前陪伴页的展示数据 + 朗读文案）。
    struct Content: Equatable {
        let generatedAt: Date
        /// 今日日记条数；日记数据未接入时为 nil
        let diaryCount: Int?
        /// 今日已到点提醒数（CareReminderStore 未接入时为 nil）
        let completedReminderCount: Int?
        /// 今日已打卡习惯数（未接入为 0）
        let habitCompletedCount: Int
        /// 今日应打卡习惯数（未接入为 0）
        let habitDueCount: Int
        /// 明日提醒数（CareReminderStore 的 upcomingReminders，fireDate 落在明天）
        let tomorrowReminderCount: Int
        let tomorrowReminderItems: [BriefItem]
        /// 明日系统待办数（RemindersCapability，dueDate 落在明天）
        let tomorrowTodoCount: Int
        let tomorrowTodoItems: [BriefItem]
        /// 明日日程数（CalendarCapability，startDate 落在明天）
        let tomorrowScheduleCount: Int
        let tomorrowScheduleItems: [BriefItem]
        /// 按时间段 + 随机挑选的晚安语
        let goodnightLine: String
        let skippedNotes: [SkipNote]
        /// TTS 朗读用的完整播报文案
        let spokenText: String
    }

    // MARK: - 依赖

    private let careStore: CareReminderStore?
    private let diaryViewModel: VoiceDiaryViewModel?
    private let habitStore: HabitStore?
    private let now: Date

    init(
        careStore: CareReminderStore? = nil,
        diaryViewModel: VoiceDiaryViewModel? = nil,
        habitStore: HabitStore? = nil,
        now: Date = Date()
    ) {
        self.careStore = careStore
        self.diaryViewModel = diaryViewModel
        self.habitStore = habitStore
        self.now = now
    }

    // MARK: - 聚合

    /// 聚合全部数据源并生成播报文案。各数据源独立降级，永不 throw。
    func build() async -> Content {
        let diary = todayDiary()
        let completedReminders = todayCompletedReminders()
        let habits = todayHabits()
        let tomorrowReminders = tomorrowReminders()
        let tomorrowTodos = await tomorrowSystemTodos()
        let tomorrowSchedule = await tomorrowSchedule()

        var notes: [SkipNote] = []
        if let note = diary.skipNote { notes.append(note) }
        if let note = habits.skipNote { notes.append(note) }
        if let note = tomorrowReminders.skipNote { notes.append(note) }
        if let note = tomorrowTodos.skipNote { notes.append(note) }
        if let note = tomorrowSchedule.skipNote { notes.append(note) }

        let goodnight = Self.goodnightLine(for: now)

        let spokenText = Self.compose(
            diaryCount: diary.count,
            diarySkipped: diary.skipNote != nil,
            completedReminderCount: completedReminders,
            habitCompletedCount: habits.completed,
            habitDueCount: habits.due,
            habitSkipped: habits.skipNote != nil,
            tomorrowReminderCount: tomorrowReminders.count,
            tomorrowReminderItems: tomorrowReminders.items,
            reminderSkipped: tomorrowReminders.skipNote != nil,
            tomorrowTodoCount: tomorrowTodos.count,
            tomorrowTodoItems: tomorrowTodos.items,
            todoSkipped: tomorrowTodos.skipNote != nil,
            tomorrowScheduleCount: tomorrowSchedule.count,
            tomorrowScheduleItems: tomorrowSchedule.items,
            scheduleSkipped: tomorrowSchedule.skipNote != nil,
            goodnightLine: goodnight,
            skippedPhrases: notes.map(\.message),
            now: now
        )

        return Content(
            generatedAt: now,
            diaryCount: diary.count,
            completedReminderCount: completedReminders,
            habitCompletedCount: habits.completed,
            habitDueCount: habits.due,
            tomorrowReminderCount: tomorrowReminders.count,
            tomorrowReminderItems: tomorrowReminders.items,
            tomorrowTodoCount: tomorrowTodos.count,
            tomorrowTodoItems: tomorrowTodos.items,
            tomorrowScheduleCount: tomorrowSchedule.count,
            tomorrowScheduleItems: tomorrowSchedule.items,
            goodnightLine: goodnight,
            skippedNotes: notes,
            spokenText: spokenText
        )
    }

    // MARK: - 今日日记（VoiceDiaryViewModel.entries）

    private func todayDiary() -> (count: Int?, skipNote: SkipNote?) {
        guard let diaryViewModel else {
            return (nil, SkipNote(section: "今日日记", message: "日记数据未接入，今日日记已跳过"))
        }
        let count = diaryViewModel.entries
            .filter { Calendar.current.isDate($0.date, inSameDayAs: now) }
            .count
        return (count, nil)
    }

    // MARK: - 今日已到点提醒（CareReminderStore）

    /// CareReminderStore 无「已完成」字段：以「今天的触发时刻已过」作为诚实口径。
    private func todayCompletedReminders() -> Int? {
        guard let careStore else { return nil }
        let calendar = Calendar.current
        let nowMinutes = calendar.component(.hour, from: now) * 60
            + calendar.component(.minute, from: now)

        return careStore.reminders.filter { reminder in
            guard reminder.enabled else { return false }
            let timeMinutes = calendar.component(.hour, from: reminder.time) * 60
                + calendar.component(.minute, from: reminder.time)

            switch reminder.repeatType {
            case .none:
                // 语音创建的一次性提醒带完整日期：今天且已过才算到点
                if let scheduled = reminder.scheduledDate {
                    return calendar.isDate(scheduled, inSameDayAs: now) && scheduled <= now
                }
                return timeMinutes <= nowMinutes
            case .daily:
                return timeMinutes <= nowMinutes
            case .workday:
                guard Self.isWorkday(now) else { return false }
                return timeMinutes <= nowMinutes
            }
        }.count
    }

    // MARK: - 今日习惯打卡（HabitStore）

    private func todayHabits() -> (completed: Int, due: Int, skipNote: SkipNote?) {
        guard let habitStore else {
            return (0, 0, SkipNote(section: "习惯打卡", message: "习惯打卡未接入，今日打卡已跳过"))
        }
        return (habitStore.todayCompletedCount, habitStore.todayDueCount, nil)
    }

    // MARK: - 明日提醒（CareReminderStore.upcomingReminders）

    private func tomorrowReminders() -> (items: [BriefItem], count: Int, skipNote: SkipNote?) {
        guard let careStore else {
            return ([], 0, SkipNote(section: "明日提醒", message: "提醒数据未接入，明日提醒已跳过"))
        }
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let tomorrowItems = careStore.upcomingReminders
            .filter { calendar.isDate($0.fireDate, inSameDayAs: tomorrow) }
            .sorted { $0.fireDate < $1.fireDate }
        let items = tomorrowItems.prefix(3).map { pair in
            BriefItem(
                id: pair.reminder.id,
                title: pair.reminder.title,
                time: pair.fireDate,
                detail: pair.reminder.category.rawValue
            )
        }
        return (items, tomorrowItems.count, nil)
    }

    // MARK: - 明日系统待办（RemindersCapability，未授权跳过）

    private func tomorrowSystemTodos() async -> (items: [BriefItem], count: Int, skipNote: SkipNote?) {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .fullAccess || status == .authorized else {
            let message: String
            switch status {
            case .writeOnly: message = "提醒事项仅写入权限，明日待办已跳过"
            case .denied, .restricted: message = "提醒事项权限未授权，明日待办已跳过"
            default: message = "提醒事项未接入，明日待办已跳过"
            }
            return ([], 0, SkipNote(section: "明日待办", message: message))
        }
        do {
            let todos = try await RemindersCapability.list(completed: false)
            let formatter = ISO8601DateFormatter()
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            let tomorrowItems = todos
                .compactMap { item -> (item: BriefItem, due: Date)? in
                    guard let due = item.dueDate.flatMap({ formatter.date(from: $0) }),
                          calendar.isDate(due, inSameDayAs: tomorrow) else { return nil }
                    return (
                        BriefItem(id: item.identifier, title: item.title, time: due, detail: item.listName),
                        due
                    )
                }
                .sorted { $0.due < $1.due }
            return (tomorrowItems.prefix(3).map { $0.item }, tomorrowItems.count, nil)
        } catch {
            return ([], 0, SkipNote(section: "明日待办", message: "待办读取失败（\(AppErrorText.localized(error.localizedDescription))）"))
        }
    }

    // MARK: - 明日日程（CalendarCapability，未授权跳过）

    private func tomorrowSchedule() async -> (items: [BriefItem], count: Int, skipNote: SkipNote?) {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else {
            let message: String
            switch status {
            case .writeOnly: message = "日历仅写入权限，明日日程已跳过"
            case .denied, .restricted: message = "日历权限未授权，明日日程已跳过"
            default: message = "日历未接入，明日日程已跳过"
            }
            return ([], 0, SkipNote(section: "明日日程", message: message))
        }
        do {
            let events = try await CalendarCapability.listEvents(daysAhead: 2, daysBack: 0)
            let formatter = ISO8601DateFormatter()
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            let tomorrowEvents = events
                .compactMap { event -> (item: BriefItem, start: Date)? in
                    guard let start = formatter.date(from: event.startDate),
                          calendar.isDate(start, inSameDayAs: tomorrow) else { return nil }
                    let location = (event.location?.isEmpty == false) ? event.location : nil
                    return (
                        BriefItem(
                            id: "\(event.title)-\(start.timeIntervalSince1970)",
                            title: event.title,
                            time: start,
                            detail: location
                        ),
                        start
                    )
                }
                .sorted { $0.start < $1.start }
            return (tomorrowEvents.prefix(3).map { $0.item }, tomorrowEvents.count, nil)
        } catch {
            return ([], 0, SkipNote(section: "明日日程", message: "日程读取失败（\(AppErrorText.localized(error.localizedDescription))）"))
        }
    }

    // MARK: - 晚安语（按时间段 + 随机柔和句）

    private static func goodnightLine(for date: Date) -> String {
        let pool: [String]
        switch Calendar.current.component(.hour, from: date) {
        case 21..<24:
            pool = [
                "晚安，愿你一夜好眠。",
                "闭上眼睛，把今天轻轻放下。",
                "睡个好觉，明天又是崭新的一天。",
                "辛苦了，今天到这里就已经足够好。",
                "世界已经安静下来，你也安心睡吧。"
            ]
        case 18..<21:
            pool = [
                "晚安，记得给自己一点放松的时间。",
                "今晚也好好休息，明天才有精神。",
                "晚安，愿梦里都是温柔的事。"
            ]
        default:
            pool = [
                "今天也辛苦了，睡前记得好好放松。",
                "晚安的意思是：今天到此为止，剩下的交给明天。",
                "好好休息，明天再继续。"
            ]
        }
        return pool.randomElement() ?? "晚安，好梦。"
    }

    // MARK: - 文案生成

    /// 生成自然语言播报文案。
    /// 规则：
    /// - 开头按时间段问候（傍晚 / 深夜 / 其他时段）。
    /// - 今日总结：日记有 → 报条数；已到点提醒 > 0 → 报条数；习惯打卡有应打卡项 → 报 X/Y。
    /// - 明日预告：提醒 / 待办 / 日程有数据 → 报数量 + 前 3 条；无数据 → 诚实说「没有」；
    ///   未授权 / 失败 → 不写「没有」，在末尾用短句标注跳过原因。
    /// - 结尾固定接晚安语 + 4-7-8 呼吸助眠引导。
    /// - 示例：「夜深了，今天辛苦啦。今天记了 2 篇日记；今天有 3 条提醒已经到点；今天的习惯打卡完成了
    ///   2 项，共 3 项；明天有 2 条提醒：「吃药」在 08:00；明天有 1 个日程：「开会」在 10:00。晚安，愿你一夜好眠。
    ///   如果想睡得再安稳些，可以跟着屏幕上的节奏做 4-7-8 呼吸：吸气四秒，屏住七秒，慢慢呼气八秒。」
    private static func compose(
        diaryCount: Int?,
        diarySkipped: Bool,
        completedReminderCount: Int?,
        habitCompletedCount: Int,
        habitDueCount: Int,
        habitSkipped: Bool,
        tomorrowReminderCount: Int,
        tomorrowReminderItems: [BriefItem],
        reminderSkipped: Bool,
        tomorrowTodoCount: Int,
        tomorrowTodoItems: [BriefItem],
        todoSkipped: Bool,
        tomorrowScheduleCount: Int,
        tomorrowScheduleItems: [BriefItem],
        scheduleSkipped: Bool,
        goodnightLine: String,
        skippedPhrases: [String],
        now: Date
    ) -> String {
        var clauses: [String] = []

        // 今日总结
        if !diarySkipped, let diaryCount {
            clauses.append(diaryCount > 0 ? "今天记了 \(diaryCount) 篇日记" : "今天没有记日记")
        }
        if let completedReminderCount, completedReminderCount > 0 {
            clauses.append("今天有 \(completedReminderCount) 条提醒已经到点")
        }
        if !habitSkipped, habitDueCount > 0 {
            clauses.append("今天的习惯打卡完成了 \(habitCompletedCount) 项，共 \(habitDueCount) 项")
        }

        // 明日预告
        if !reminderSkipped {
            if tomorrowReminderCount > 0 {
                clauses.append("明天有 \(tomorrowReminderCount) 条提醒：\(listPhrase(tomorrowReminderItems, total: tomorrowReminderCount))")
            } else {
                clauses.append("明天没有要响的提醒")
            }
        }
        if !todoSkipped {
            if tomorrowTodoCount > 0 {
                clauses.append("明天还有 \(tomorrowTodoCount) 件待办：\(listPhrase(tomorrowTodoItems, total: tomorrowTodoCount))")
            } else {
                clauses.append("明天没有待办")
            }
        }
        if !scheduleSkipped {
            if tomorrowScheduleCount > 0 {
                clauses.append("明天有 \(tomorrowScheduleCount) 个日程：\(listPhrase(tomorrowScheduleItems, total: tomorrowScheduleCount))")
            } else {
                clauses.append("明天没有日程安排")
            }
        }

        let opening = Self.opening(for: now)
        var text = opening + (clauses.isEmpty ? "" : " " + clauses.joined(separator: "；") + "。")
        text += " " + goodnightLine + "。"
        text += " 如果想睡得再安稳些，可以跟着屏幕上的节奏做 4-7-8 呼吸：吸气四秒，屏住七秒，慢慢呼气八秒。"
        if !skippedPhrases.isEmpty {
            text += " " + skippedPhrases.joined(separator: "；") + "。"
        }
        return text
    }

    private static func opening(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 18..<21: return "晚上好，今天辛苦啦。"
        case 21..<24: return "夜深了，今天辛苦啦。"
        case 0..<6: return "夜深了，该休息啦。"
        default: return "晚上好，先来听听今天的回顾吧。"
        }
    }

    /// 条目列表短语：最多 3 条；超出时补「等」。
    private static func listPhrase(_ items: [BriefItem], total: Int) -> String {
        let listed = items.map { item in
            if let timeText = item.timeText {
                return "「\(item.title)」在 \(timeText)"
            }
            return "「\(item.title)」"
        }
        .joined(separator: "；")
        guard total > items.count else { return listed }
        return listed + " 等"
    }

    private static func isWorkday(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return (2...6).contains(weekday)
    }
}
