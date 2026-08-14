import Foundation
import EventKit

/// 每日一站式播报引擎：聚合今日提醒/日程/待办、昨日日记、自动化下次执行，
/// 生成一段自然语言播报文案，供 TTS 一键朗读。
///
/// 诚实原则（不造假）：
/// - 每个数据源独立读取；失败或未授权时降级跳过，并在 `skippedNotes` 与文案中标注原因。
/// - 天气走 OpenWeatherMap（Key 在「设置 > 每日播报 · 天气」填写）；未填 Key 或读取失败时如实跳过并标注原因。
/// - 未注入 diaryViewModel / automationViewModel 时，对应分区按「未接入」展示。
///
/// 使用（主智能体接线）：
/// ```swift
/// let engine = DailyBriefingEngine(
///     careStore: careStore,
///     diaryViewModel: diaryViewModel,          // 可选
///     automationViewModel: automationViewModel // 可选
/// )
/// let content = await engine.build()
/// ```
@MainActor
struct DailyBriefingEngine {

    /// 播报分区里的一条条目（提醒/日程/待办共用展示结构）。
    struct BriefItem: Identifiable, Equatable {
        let id: String
        let title: String
        /// 触发/开始/截止时间；无时间信息时为 nil
        let time: Date?
        /// 附加说明（如日程地点、提醒类别、待办列表名）
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

    /// 一次聚合的快照（播报页的展示数据 + 朗读文案）。
    struct Content: Equatable {
        let generatedAt: Date
        let reminderCount: Int
        let reminderItems: [BriefItem]
        let scheduleCount: Int
        let scheduleItems: [BriefItem]
        let todoCount: Int
        let todoItems: [BriefItem]
        let diaryCount: Int
        let automationTaskName: String?
        let automationNextRunAt: Date?
        /// 今日天气（未配置 Key / 读取失败时为 nil，页面如实显示空态）
        let weather: WeatherInfo?
        let skippedNotes: [SkipNote]
        /// TTS 朗读用的完整播报文案
        let spokenText: String
    }

    // MARK: - 依赖

    private let careStore: CareReminderStore
    private let diaryViewModel: VoiceDiaryViewModel?
    private let automationViewModel: AutomationViewModel?
    /// 天气 API Key（nil/空 = 未配置，播报如实跳过天气）
    private let weatherAPIKey: String?
    /// 天气查询城市（OpenWeatherMap 按城市名查询）
    private let weatherCity: String
    private let now: Date

    init(
        careStore: CareReminderStore,
        diaryViewModel: VoiceDiaryViewModel? = nil,
        automationViewModel: AutomationViewModel? = nil,
        weatherAPIKey: String? = nil,
        weatherCity: String = "上海",
        now: Date = Date()
    ) {
        self.careStore = careStore
        self.diaryViewModel = diaryViewModel
        self.automationViewModel = automationViewModel
        self.weatherAPIKey = weatherAPIKey
        self.weatherCity = weatherCity
        self.now = now
    }

    // MARK: - 聚合

    /// 聚合全部数据源并生成播报文案。各数据源独立降级，永不 throw。
    func build() async -> Content {
        let reminders = todayReminders()
        let schedule = await todaySchedule()
        let todos = await todayTodos()
        let diary = yesterdayDiaryCount()
        let automation = nextAutomationRun()
        let weather = await currentWeather()

        var notes: [SkipNote] = []
        if let note = schedule.skipNote { notes.append(note) }
        if let note = todos.skipNote { notes.append(note) }
        if let note = diary.skipNote { notes.append(note) }
        if let note = automation.skipNote { notes.append(note) }
        if let note = weather.skipNote { notes.append(note) }

        let spokenText = Self.compose(
            reminderCount: reminders.count,
            reminderItems: reminders.items,
            scheduleCount: schedule.count,
            scheduleItems: schedule.items,
            scheduleSkipped: schedule.skipNote != nil,
            todoCount: todos.count,
            todoItems: todos.items,
            todoSkipped: todos.skipNote != nil,
            diaryCount: diary.count,
            diarySkipped: diary.skipNote != nil,
            automationTaskName: automation.taskName,
            automationNextRunAt: automation.nextRunAt,
            weather: weather.info,
            skippedPhrases: notes.map(\.message),
            now: now
        )

        return Content(
            generatedAt: now,
            reminderCount: reminders.count,
            reminderItems: reminders.items,
            scheduleCount: schedule.count,
            scheduleItems: schedule.items,
            todoCount: todos.count,
            todoItems: todos.items,
            diaryCount: diary.count,
            automationTaskName: automation.taskName,
            automationNextRunAt: automation.nextRunAt,
            weather: weather.info,
            skippedNotes: notes,
            spokenText: spokenText
        )
    }

    // MARK: - 今日提醒（CareReminderStore）

    private func todayReminders() -> (items: [BriefItem], count: Int) {
        let todays = careStore.upcomingReminders
            .filter { Calendar.current.isDate($0.fireDate, inSameDayAs: now) }
            .sorted { $0.fireDate < $1.fireDate }
        let items = todays.prefix(3).map { pair in
            BriefItem(
                id: pair.reminder.id,
                title: pair.reminder.title,
                time: pair.fireDate,
                detail: pair.reminder.category.rawValue
            )
        }
        return (items, todays.count)
    }

    // MARK: - 今日日程（CalendarCapability）

    private func todaySchedule() async -> (items: [BriefItem], count: Int, skipNote: SkipNote?) {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else {
            return ([], 0, SkipNote(section: "日程", message: scheduleSkipMessage(for: status)))
        }
        do {
            let events = try await CalendarCapability.listEvents(daysAhead: 1, daysBack: 1)
            let formatter = ISO8601DateFormatter()
            let todays = events
                .compactMap { event -> (item: BriefItem, start: Date)? in
                    guard let start = formatter.date(from: event.startDate),
                          Calendar.current.isDate(start, inSameDayAs: now) else { return nil }
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
            return (todays.prefix(3).map { $0.item }, todays.count, nil)
        } catch {
            return ([], 0, SkipNote(section: "日程", message: "日程读取失败（\(AppErrorText.localized(error.localizedDescription))）"))
        }
    }

    private func scheduleSkipMessage(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .writeOnly: return "日历仅写入权限，日程已跳过"
        case .denied, .restricted: return "日历权限未授权，日程已跳过"
        default: return "日历未接入，日程已跳过"
        }
    }

    // MARK: - 今日待办（RemindersCapability）

    private func todayTodos() async -> (items: [BriefItem], count: Int, skipNote: SkipNote?) {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .fullAccess || status == .authorized else {
            let message: String
            switch status {
            case .writeOnly: message = "提醒事项仅写入权限，待办已跳过"
            case .denied, .restricted: message = "提醒事项权限未授权，待办已跳过"
            default: message = "提醒事项未接入，待办已跳过"
            }
            return ([], 0, SkipNote(section: "待办", message: message))
        }
        do {
            let todos = try await RemindersCapability.list(completed: false)
            let formatter = ISO8601DateFormatter()
            let todays = todos
                .compactMap { item -> (item: BriefItem, due: Date)? in
                    guard let dueDate = item.dueDate.flatMap({ formatter.date(from: $0) }),
                          Calendar.current.isDate(dueDate, inSameDayAs: now) else { return nil }
                    return (
                        BriefItem(id: item.identifier, title: item.title, time: dueDate, detail: item.listName),
                        dueDate
                    )
                }
                .sorted { $0.due < $1.due }
            return (todays.prefix(3).map { $0.item }, todays.count, nil)
        } catch {
            return ([], 0, SkipNote(section: "待办", message: "待办读取失败（\(AppErrorText.localized(error.localizedDescription))）"))
        }
    }

    // MARK: - 昨日日记（VoiceDiaryViewModel.entries）

    private func yesterdayDiaryCount() -> (count: Int, skipNote: SkipNote?) {
        guard let diaryViewModel else {
            return (0, SkipNote(section: "日记", message: "日记数据未接入，昨日日记已跳过"))
        }
        let count = diaryViewModel.entries
            .filter { Calendar.current.isDateInYesterday($0.date) }
            .count
        return (count, nil)
    }

    // MARK: - 自动化下次执行（AutomationViewModel.tasks）

    private func nextAutomationRun() -> (taskName: String?, nextRunAt: Date?, skipNote: SkipNote?) {
        guard let automationViewModel else {
            return (nil, nil, SkipNote(section: "自动化", message: "自动化未接入，下次执行已跳过"))
        }
        let enabledTasks = automationViewModel.tasks.filter { $0.enabled }
        guard let next = enabledTasks.compactMap({ $0.nextRunAt }).min() else {
            // 无已启用任务或尚未排程：不是失败，正文不写这一项（页面如实显示「暂无」）
            return (nil, nil, nil)
        }
        let name = enabledTasks.first { $0.nextRunAt == next }?.name
        return (name, next, nil)
    }

    // MARK: - 今日天气（OpenWeatherMap；Key 在「设置 > 每日播报 · 天气」填写）

    /// 天气独立降级：未配置 Key / 请求失败时返回 skipNote，绝不造假。
    private func currentWeather() async -> (info: WeatherInfo?, skipNote: SkipNote?) {
        guard let weatherAPIKey, !weatherAPIKey.isEmpty else {
            return (nil, SkipNote(section: "天气", message: "天气未配置 API Key（设置 > 每日播报 · 天气），暂不播报天气"))
        }
        do {
            let info = try await WeatherService.fetch(city: weatherCity, apiKey: weatherAPIKey)
            return (info, nil)
        } catch {
            return (nil, SkipNote(section: "天气", message: "天气读取失败（\(AppErrorText.localized(error.localizedDescription))）"))
        }
    }

    // MARK: - 文案生成

    /// 生成自然语言播报文案。
    /// 规则：
    /// - 开头按时间段打招呼（早上好/上午好/中午好/下午好/晚上好/夜深了）。
    /// - 各分区有数据 → 「今天有 N 条提醒：…」；无数据且未跳过 → 诚实说「没有」。
    /// - 分区失败/未授权 → 不写「没有」，改用短句标注（如「日历未授权，日程已跳过」）。
    /// - 天气已配 Key → 播报城市/天气/气温；无 Key → 不写「没有」，改由末尾跳过短语说明。
    /// - 示例：「早上好！今天有 3 条提醒：「吃药」在 08:00；今天有 2 个日程：「开会」在 10:00。昨天记了 2 篇日记。自动化任务「晨报」下次在 15:00 执行。天气暂未接入。日历未授权，日程已跳过。」
    private static func compose(
        reminderCount: Int,
        reminderItems: [BriefItem],
        scheduleCount: Int,
        scheduleItems: [BriefItem],
        scheduleSkipped: Bool,
        todoCount: Int,
        todoItems: [BriefItem],
        todoSkipped: Bool,
        diaryCount: Int,
        diarySkipped: Bool,
        automationTaskName: String?,
        automationNextRunAt: Date?,
        weather: WeatherInfo?,
        skippedPhrases: [String],
        now: Date
    ) -> String {
        let greeting = Self.greeting(for: now)

        var clauses: [String] = []

        if reminderCount > 0 {
            clauses.append("今天有 \(reminderCount) 条提醒：\(Self.listPhrase(reminderItems, total: reminderCount))")
        } else {
            clauses.append("今天没有要响的提醒")
        }

        if !scheduleSkipped {
            if scheduleCount > 0 {
                clauses.append("今天有 \(scheduleCount) 个日程：\(Self.listPhrase(scheduleItems, total: scheduleCount))")
            } else {
                clauses.append("今天没有日程安排")
            }
        }

        if !todoSkipped {
            if todoCount > 0 {
                clauses.append("今天还有 \(todoCount) 件待办：\(Self.listPhrase(todoItems, total: todoCount))")
            } else {
                clauses.append("今天没有待办")
            }
        }

        if !diarySkipped {
            clauses.append(diaryCount > 0 ? "昨天记了 \(diaryCount) 篇日记" : "昨天没有记日记")
        }

        if let automationNextRunAt {
            let name = automationTaskName.map { "「\($0)」" } ?? ""
            clauses.append("自动化任务\(name)下次在 \(Self.timeText(automationNextRunAt)) 执行")
        }

        if let weather {
            clauses.append("\(weather.city)今天\(weather.condition)，气温 \(weather.low)～\(weather.high)℃，当前 \(weather.temperature)℃")
        }

        var text = greeting + " " + clauses.joined(separator: "；")
        if !skippedPhrases.isEmpty {
            text += "。" + skippedPhrases.joined(separator: "；")
        }
        return text + "。"
    }

    private static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<9: return "早上好！"
        case 9..<12: return "上午好！"
        case 12..<14: return "中午好！"
        case 14..<18: return "下午好！"
        case 18..<24: return "晚上好！"
        default: return "夜深了，注意休息。"
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

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
