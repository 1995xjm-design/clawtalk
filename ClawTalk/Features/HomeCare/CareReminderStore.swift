import Foundation
import Observation
import UserNotifications

/// 居家健康提醒存储：UserDefaults（JSON 序列化）增删改查 + 到点本地通知调度。
///
/// 通知：
/// - 权限由主 App 的 PushManager 统一申请过，这里只调度 UNNotificationRequest，不重复弹授权。
/// - 到点响铃：content.sound = .default（NotificationCapability 的调用方式可读参考）。
/// - daily 用一个按「时:分」重复的日历触发器；workday 拆成 5 个工作日周重复触发器；
///   一次性（none）只排下一次触发（今天时间已过则不排，列表照常保留，诚实显示）。
@Observable
@MainActor
final class CareReminderStore {

    private(set) var reminders: [CareReminder] = []
    /// 通知权限被系统拒绝时置 true（列表页用于提示，不弹授权框）
    private(set) var notificationPermissionDenied = false
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "健康提醒", errorMessage)
            }
        }
    }

    private let storageKey = "clawtalk_care_reminders_v1"
    /// Calendar：1=周日 … 6=周五
    private let workdayWeekdays = [2, 3, 4, 5, 6]

    init() {
        load()
    }

    // MARK: - 查询

    /// 未来将触发的提醒（按触发时间升序），供卡片「最近一条」与计数使用。
    var upcomingReminders: [(reminder: CareReminder, fireDate: Date)] {
        reminders.compactMap { reminder in
            guard let fireDate = nextFireDate(for: reminder) else { return nil }
            return (reminder, fireDate)
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    /// 今天还会触发的提醒数量（卡片「今日 N 条」）。
    var todayReminderCount: Int {
        upcomingReminders.filter { Calendar.current.isDate($0.fireDate, inSameDayAs: Date()) }.count
    }

    /// 最近一条将触发的提醒（无则 nil，卡片显示诚实空态）。
    var nextReminder: CareReminder? {
        upcomingReminders.first?.reminder
    }

    /// 提醒下一次触发时间；已禁用或一次性已过点返回 nil。
    func nextFireDate(for reminder: CareReminder) -> Date? {
        guard reminder.enabled else { return nil }
        let calendar = Calendar.current
        let now = Date()
        let time = calendar.dateComponents([.hour, .minute], from: reminder.time)
        let todayTime = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: now)

        switch reminder.repeatType {
        case .none:
            guard let todayTime, todayTime > now else { return nil }
            return todayTime
        case .daily:
            if let todayTime, todayTime > now { return todayTime }
            return calendar.date(byAdding: .day, value: 1, to: todayTime ?? now)
        case .workday:
            var candidate = todayTime ?? now
            if candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            while !Self.isWorkday(candidate) {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            return candidate
        }
    }

    // MARK: - 增删改查

    @discardableResult
    func add(_ reminder: CareReminder) -> CareReminder {
        reminders.append(reminder)
        sortByTime()
        persist()
        reschedule(for: reminder)
        return reminder
    }

    func update(_ reminder: CareReminder) {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        reminders[index] = reminder
        sortByTime()
        persist()
        reschedule(for: reminder)
    }

    func delete(id: String) {
        guard let reminder = reminders.first(where: { $0.id == id }) else { return }
        cancelNotifications(for: reminder)
        reminders.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].enabled = enabled
        persist()
        if enabled {
            reschedule(for: reminders[index])
        } else {
            cancelNotifications(for: reminders[index])
        }
    }

    // MARK: - 本地持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CareReminder].self, from: data)
        else {
            reminders = []
            return
        }
        reminders = decoded.sorted { timeOfDay($0.time) < timeOfDay($1.time) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func sortByTime() {
        reminders.sort { timeOfDay($0.time) < timeOfDay($1.time) }
    }

    private func timeOfDay(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    // MARK: - 本地通知调度

    /// 取消旧通知后按当前状态重新调度（add/update/开启时调用）。
    private func reschedule(for reminder: CareReminder) {
        cancelNotifications(for: reminder)
        guard reminder.enabled else { return }
        Task { await scheduleNotifications(for: reminder) }
    }

    private func cancelNotifications(for reminder: CareReminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: Self.notificationIdentifiers(for: reminder)
        )
    }

    private func scheduleNotifications(for reminder: CareReminder) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            if settings.authorizationStatus == .denied {
                notificationPermissionDenied = true
            }
            return
        }
        notificationPermissionDenied = false

        let content = UNMutableNotificationContent()
        content.title = "\(reminder.category.rawValue)提醒"
        content.body = reminder.title
        content.sound = .default
        content.userInfo = ["care_reminder_id": reminder.id]

        for (identifier, trigger) in notificationTriggers(for: reminder) {
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                errorMessage = "提醒通知调度失败：\(error.localizedDescription)"
            }
        }
    }

    private func notificationTriggers(for reminder: CareReminder) -> [(String, UNCalendarNotificationTrigger)] {
        let calendar = Calendar.current
        let baseID = Self.notificationBaseIdentifier(for: reminder.id)
        let time = calendar.dateComponents([.hour, .minute], from: reminder.time)

        switch reminder.repeatType {
        case .none:
            guard let fireDate = nextFireDate(for: reminder) else { return [] }
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            return [(baseID, UNCalendarNotificationTrigger(dateMatching: components, repeats: false))]
        case .daily:
            return [(baseID, UNCalendarNotificationTrigger(dateMatching: time, repeats: true))]
        case .workday:
            return workdayWeekdays.map { weekday in
                var components = time
                components.weekday = weekday
                return ("\(baseID)-\(weekday)", UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
            }
        }
    }

    // MARK: - 通知标识

    static func notificationBaseIdentifier(for reminderID: String) -> String {
        "care-reminder-\(reminderID)"
    }

    static func notificationIdentifiers(for reminder: CareReminder) -> [String] {
        let base = notificationBaseIdentifier(for: reminder.id)
        switch reminder.repeatType {
        case .none, .daily:
            return [base]
        case .workday:
            return [2, 3, 4, 5, 6].map { "\(base)-\($0)" }
        }
    }

    private static func isWorkday(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return (2...6).contains(weekday)
    }
}
