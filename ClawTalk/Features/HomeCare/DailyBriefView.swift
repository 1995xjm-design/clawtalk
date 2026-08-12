import SwiftUI
import EventKit

/// 每日简报页：今天的提醒（CareReminderStore）+ 日程 + 待办 + 天气。
///
/// 数据源（诚实，不造假）：
/// - 提醒：CareReminderStore（本地创建的居家提醒，今日将触发的展示出来）
/// - 日程/待办：走现有 CalendarCapability / RemindersCapability（真实数据）；
///   未授权时不弹权限弹窗，显示空状态与引导文案。
/// - 天气：暂无天气 API key，仅空状态说明；待主智能体接入天气接口后替换。
/// - 早上推送：本页只负责展示；早上定时把简报内容推送给用户的本地通知，
///   由主智能体在接入天气接口后统一安排（可复用 NotificationCapability）。
struct DailyBriefView: View {
    @State private var careStore: CareReminderStore
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var calendarStatus: EKAuthorizationStatus = .notDetermined
    @State private var remindersStatus: EKAuthorizationStatus = .notDetermined
    @State private var scheduleItems: [BriefScheduleItem] = []
    @State private var todoItems: [BriefTodoItem] = []

    private let isoFormatter = ISO8601DateFormatter()

    init(store: CareReminderStore? = nil) {
        _careStore = State(initialValue: store ?? CareReminderStore())
    }

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            careSection
            scheduleSection
            todoSection
            weatherSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("每日简报")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - 今天的提醒（CareReminderStore）

    @ViewBuilder
    private var careSection: some View {
        Section {
            if careStore.reminders.isEmpty {
                emptyStateRow("今天暂无提醒", detail: "在「提醒」卡片里创建的居家提醒会显示在这里")
            } else {
                let todays = careStore.upcomingReminders
                    .filter { Calendar.current.isDateInToday($0.fireDate) }
                    .map { BriefCareItem(reminder: $0.reminder, fireDate: $0.fireDate) }
                if todays.isEmpty {
                    emptyStateRow("今天暂无提醒", detail: "今天没有将触发的提醒，已过点的提醒不会重复显示")
                } else {
                    ForEach(todays) { item in
                        careRow(item)
                    }
                }
            }
        } header: {
            Label("今天的提醒", systemImage: "bell.badge")
        }
    }

    private func careRow(_ item: BriefCareItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeText(item.fireDate))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(width: 52, alignment: .leading)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.reminder.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Label(item.reminder.category.rawValue, systemImage: item.reminder.category.iconName)
                    .font(.caption2)
                    .foregroundStyle(item.reminder.category.themeColor)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 日程

    @ViewBuilder
    private var scheduleSection: some View {
        Section {
            switch calendarStatus {
            case .fullAccess, .authorized:
                if scheduleItems.isEmpty {
                    emptyStateRow("今天暂无日程", detail: "日历里没有安排，好好休息一下")
                } else {
                    ForEach(scheduleItems) { item in
                        scheduleRow(item)
                    }
                }
            case .writeOnly:
                emptyStateRow("日历仅写入权限", detail: "无法读取今天的日程，可在系统设置调整")
            case .denied, .restricted:
                emptyStateRow("未授权日历权限", detail: "在系统设置允许 ClawTalk 访问日历后，这里会显示今天的日程")
            case .notDetermined:
                emptyStateRow("日历未接入", detail: "授权日历权限后显示今天的日程")
            @unknown default:
                emptyStateRow("日历未接入", detail: "授权日历权限后显示今天的日程")
            }
        } header: {
            Label("今天的日程", systemImage: "calendar")
        }
    }

    private func scheduleRow(_ item: BriefScheduleItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeText(item.start))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(width: 52, alignment: .leading)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let location = item.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 待办

    @ViewBuilder
    private var todoSection: some View {
        Section {
            switch remindersStatus {
            case .fullAccess, .authorized:
                if todoItems.isEmpty {
                    emptyStateRow("今天暂无待办", detail: "提醒事项里没有安排在今天的事项")
                } else {
                    ForEach(todoItems) { item in
                        todoRow(item)
                    }
                }
            case .writeOnly:
                emptyStateRow("提醒事项仅写入权限", detail: "无法读取今天的待办，可在系统设置调整")
            case .denied, .restricted:
                emptyStateRow("未授权提醒事项权限", detail: "在系统设置允许 ClawTalk 访问提醒事项后，这里会显示今天的待办")
            case .notDetermined:
                emptyStateRow("提醒事项未接入", detail: "授权提醒事项权限后显示今天的待办")
            @unknown default:
                emptyStateRow("提醒事项未接入", detail: "授权提醒事项权限后显示今天的待办")
            }
        } header: {
            Label("今天的待办", systemImage: "checklist")
        }
    }

    private func todoRow(_ item: BriefTodoItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let dueDate = item.dueDate {
                    Text("截止 \(timeText(dueDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 天气

    private var weatherSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("天气待接入", systemImage: "cloud.sun")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("这里将展示今天的天气概况（气温 / 天气 / 穿衣建议）。需要天气 API key，暂无接口；接入后替换此空状态。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        } header: {
            Label("今天的天气", systemImage: "cloud.sun")
        }
    }

    // MARK: - 加载

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        loadError = nil

        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        if calendarStatus == .fullAccess || calendarStatus == .authorized {
            do {
                let events = try await CalendarCapability.listEvents(daysAhead: 1, daysBack: 1)
                scheduleItems = events.compactMap { item -> BriefScheduleItem? in
                    guard let start = isoFormatter.date(from: item.startDate),
                          Calendar.current.isDateInToday(start) else { return nil }
                    return BriefScheduleItem(
                        id: "\(item.title)-\(start.timeIntervalSince1970)",
                        title: item.title,
                        start: start,
                        location: item.location
                    )
                }
                .sorted { $0.start < $1.start }
            } catch {
                loadError = "日程加载失败：\(error.localizedDescription)"
            }
        }

        remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        if remindersStatus == .fullAccess || remindersStatus == .authorized {
            do {
                let todos = try await RemindersCapability.list(completed: false)
                todoItems = todos.compactMap { item -> BriefTodoItem? in
                    guard let dueDate = item.dueDate.flatMap({ isoFormatter.date(from: $0) }),
                          Calendar.current.isDateInToday(dueDate) else { return nil }
                    return BriefTodoItem(id: item.identifier, title: item.title, dueDate: dueDate)
                }
                .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            } catch {
                loadError = "待办加载失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 通用

    @ViewBuilder
    private func emptyStateRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// 简报页居家提醒条目（仅展示，来自 CareReminderStore）。
private struct BriefCareItem: Identifiable {
    let id: String
    let reminder: CareReminder
    let fireDate: Date

    init(reminder: CareReminder, fireDate: Date) {
        self.id = reminder.id
        self.reminder = reminder
        self.fireDate = fireDate
    }
}

/// 简报页日程条目（仅展示，来自日历能力）。
struct BriefScheduleItem: Identifiable {
    let id: String
    let title: String
    let start: Date
    let location: String?
}

/// 简报页待办条目（仅展示，来自提醒事项能力）。
struct BriefTodoItem: Identifiable {
    let id: String
    let title: String
    let dueDate: Date?
}

// MARK: - 副主页入口（主智能体接线用）

/// 副主页「每日简报」入口：Button + fullScreenCover。
/// 用法：放进副主页卡片区或工具栏即可（样式可随卡片网格调整）。
/// 卡片网格推荐用 DailyBriefCardView（同款卡片样式，点击进 NavigationLink 简报页）。
struct DailyBriefEntryButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("每日简报", systemImage: "sun.max")
                .foregroundStyle(Color.openClawRed)
        }
        .fullScreenCover(isPresented: $isPresented) {
            NavigationStack {
                DailyBriefView()
            }
        }
    }
}