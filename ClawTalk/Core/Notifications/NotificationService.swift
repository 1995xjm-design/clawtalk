import Foundation
import UserNotifications

/// 通知中心抽象（对齐官方 NotificationService / LiveNotificationCenter）：
/// 统一授权状态查询 + 本地通知增删，便于替换/测试。
protocol NotificationCentering {
    var authorizationStatus: UNAuthorizationStatus { get async }
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func deliveredNotifications() async -> [UNNotification]
}

/// 实时通知中心（UserNotifications 实现）。
struct LiveNotificationCenter: NotificationCentering {
    static let shared = LiveNotificationCenter()

    var authorizationStatus: UNAuthorizationStatus {
        get async {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func deliveredNotifications() async -> [UNNotification] {
        await UNUserNotificationCenter.current().deliveredNotifications()
    }
}

enum NotificationAuthorizationStatus {
    static func current() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static var isAuthorized: Bool {
        get async {
            let status = await current()
            return status == .authorized || status == .provisional || status == .ephemeral
        }
    }
}

/// 通知服务偏好（对齐官方 NotificationServingPreference）：通知转发开关。
enum NotificationServingPreference {
    static let key = "notifications.serving.enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// 通知操作运行器（对齐官方 NotificationOperationRunner）：串行执行通知操作。
@MainActor
final class NotificationOperationRunner {
    private var continuation: CheckedContinuation<Void, Never>?

    func setContinuation(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// 通知调用门闩（对齐官方 NotificationInvokeLatch）：防止通知回调重入。
@MainActor
final class NotificationInvokeLatch {
    private var isLocked = false

    func run(_ action: () async -> Void) async {
        guard !isLocked else { return }
        isLocked = true
        defer { isLocked = false }
        await action()
    }
}
