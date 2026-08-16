import Foundation
import EventKit

/// 提醒事项能力（任务 G）：读提醒/新建提醒，返回结构化结果；权限不足返回明确错误。
/// 注：NodeConnection 目前把 reminders.list/add 路由到 CalendarCapability，
/// 主智能体可自行决定是否改路由到本文件（两者实现等价，本文件使用 iOS 17 全量权限 API）。
enum RemindersCapability {

    struct ReminderItem: Encodable {
        let identifier: String
        let title: String
        let isCompleted: Bool
        let dueDate: String?
        let notes: String?
        let priority: Int
        let listName: String
    }

    struct AddResult: Encodable {
        let ok: Bool
        let identifier: String
    }

    enum RemindersError: LocalizedError {
        case denied
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .denied: return "提醒事项权限被拒绝"
            case .unavailable(let message): return message
            }
        }
    }

    private static let store = EKEventStore()

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 读取提醒事项（可选只读已完成/未完成），按截止时间倒序返回前 limit 条。
    static func list(completed: Bool? = nil, limit: Int = 50) async throws -> [ReminderItem] {
        try await requestAccess()

        let predicate = store.predicateForReminders(in: nil)
        let reminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { fetched in
                continuation.resume(returning: fetched ?? [])
            }
        }

        let filtered = reminders.filter { reminder in
            if let completed { return reminder.isCompleted == completed }
            return true
        }

        let sorted = filtered.sorted { lhs, rhs in
            let lhsDate = lhs.dueDateComponents?.date ?? .distantPast
            let rhsDate = rhs.dueDateComponents?.date ?? .distantPast
            return lhsDate > rhsDate
        }

        return sorted.prefix(limit).map { item(from: $0) }
    }

    /// 新建提醒事项。
    static func add(
        title: String,
        dueDate: Date?,
        notes: String?,
        priority: Int,
        listId: String? = nil,
        listName: String? = nil
    ) async throws -> AddResult {
        try await requestAccess()

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: dueDate
            )
        }
        reminder.priority = min(9, max(0, priority))

        let calendar: EKCalendar
        if let listId, let matched = store.calendar(withIdentifier: listId) {
            calendar = matched
        } else if let listName, !listName.isEmpty,
                  let matched = store.calendars(for: .reminder).first(where: { $0.title == listName }) {
            calendar = matched
        } else if let fallback = store.defaultCalendarForNewReminders()
                ?? store.calendars(for: .reminder).first {
            calendar = fallback
        } else {
            throw RemindersError.unavailable("没有可用的提醒事项列表")
        }
        reminder.calendar = calendar

        try store.save(reminder, commit: true)
        return AddResult(ok: true, identifier: reminder.calendarItemIdentifier)
    }

    // MARK: - Private

    private static func requestAccess() async throws {
        do {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else { throw RemindersError.denied }
        } catch let error as RemindersError {
            throw error
        } catch {
            throw RemindersError.unavailable(error.localizedDescription)
        }
    }

    private static func item(from reminder: EKReminder) -> ReminderItem {
        ReminderItem(
            identifier: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            isCompleted: reminder.isCompleted,
            dueDate: reminder.dueDateComponents?.date.map { formatter.string(from: $0) },
            notes: reminder.notes,
            priority: reminder.priority,
            listName: reminder.calendar?.title ?? "默认"
        )
    }
}