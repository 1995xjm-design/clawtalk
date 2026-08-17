import Foundation
import UIKit
import UserNotifications
import OSLog

extension Notification.Name {
    /// deviceToken 变化（object 为 token 字符串）
    static let clawTalkDeviceTokenDidChange = Notification.Name("clawTalkDeviceTokenDidChange")
    /// 收到远程推送（object 为 userInfo）
    static let clawTalkRemoteNotificationReceived = Notification.Name("clawTalkRemoteNotificationReceived")
}

/// 远程推送管理：APNs 注册、deviceToken 获取与网关上报、静默推送/远程通知转本地通知。
///
/// 接线（由主智能体在 ClawTalkApp 完成）：
/// 1. 启动时调用 `PushManager.shared.requestNotificationPermissionIfNeeded()` 或 `requestAuthorizationAndRegister()`
/// 2. 通过 UIApplicationDelegateAdaptor 接收 APNs 回调并转发：
///    - didRegisterForRemoteNotificationsWithDeviceToken -> PushManager.shared.handleDeviceToken(_:)
///    - didFailToRegisterForRemoteNotifications -> PushManager.shared.handleRegistrationFailure(_:)
///    - didReceiveRemoteNotification -> PushManager.shared.handleRemoteNotification(userInfo:)
/// 3. 首次拿到 token 后调用 `reportIfConfigured(settings:)` 上报（或在 AppDelegate 回调里调用）
///
/// 前置条件（主智能体接线时补充）：
/// - entitlements 增加 aps-environment
/// - Info.plist UIBackgroundModes 增加 remote-notification
@MainActor
@Observable
final class PushManager {
    static let shared = PushManager()

    enum APNSState: Equatable {
        case notRegistered
        case registered
        case failed(String)
    }

    /// 推送指令专用会话 key（与电脑端 OpenClaw 的固定会话）
    static let pushSessionKey = "agent:main:clawtalk-user:push"

    private let logger = Logger(subsystem: "com.openclaw.clawtalk", category: "push")
    private let defaults = UserDefaults.standard
    private let tokenKey = "clawtalk_apns_device_token"

    private(set) var apnsState: APNSState = .notRegistered
    private(set) var lastReportError: String?

    /// 最近一次拿到的 APNs deviceToken（十六进制字符串）
    var deviceToken: String? {
        defaults.string(forKey: tokenKey)
    }

    private init() {}

    // MARK: - 通知权限引导

    /// 首次启动引导：仅在用户从未决定时请求通知权限（不打扰已决定过的用户）。
    func requestNotificationPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// 请求通知权限并注册 APNs。
    func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted {
                registerForRemoteNotifications()
            } else {
                apnsState = .failed("通知权限被拒绝，无法接收远程推送")
            }
        case .authorized, .provisional, .ephemeral:
            registerForRemoteNotifications()
        case .denied:
            apnsState = .failed("通知权限被拒绝，请在系统设置中开启")
        @unknown default:
            registerForRemoteNotifications()
        }
    }

    /// 向系统注册远程通知（需要 APNs entitlement；模拟器会回调失败，属正常现象）。
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
        logger.info("requesting APNs registration")
    }

    // MARK: - APNs 回调（由 AppDelegate 转发）

    func handleDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: tokenKey)
        apnsState = .registered
        lastReportError = nil
        logger.info("APNs device token received")
        NotificationCenter.default.post(name: .clawTalkDeviceTokenDidChange, object: token)
    }

    func handleRegistrationFailure(_ error: Error) {
        apnsState = .failed(error.localizedDescription)
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - 远程通知接收

    /// 收到远程推送：前台时用本地通知补齐显示（复用 NotificationCapability）；
    /// 静默推送（content-available）时尝试后台拉取网关新消息。
    func handleRemoteNotification(userInfo: [AnyHashable: Any]) {
        NotificationCenter.default.post(name: .clawTalkRemoteNotificationReceived, object: userInfo)

        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let contentAvailable = (aps?["content-available"] as? Int) == 1
        let hasAlert = aps?["alert"] != nil

        if hasAlert && UIApplication.shared.applicationState == .active {
            let title: String
            let body: String
            if let dict = aps?["alert"] as? [AnyHashable: Any] {
                title = dict["title"] as? String ?? "ClawTalk"
                body = dict["body"] as? String ?? ""
            } else {
                title = "ClawTalk"
                body = aps?["alert"] as? String ?? ""
            }
            Task {
                try? await NotificationCapability.notify(title: title, body: body, sound: nil, priority: nil)
            }
        }

        if contentAvailable {
            // 静默推送：短连网关拉取专用会话的新消息（复用 BGAppRefreshManager 的拉取逻辑）
            Task {
                _ = await BGAppRefreshManager.shared.checkForNewMessages()
            }
        }
    }

    // MARK: - 上报网关

    /// 通过网关 chat 把 deviceToken 上报到专用会话（电脑端 OpenClaw 可查看并记录）。
    @discardableResult
    func reportDeviceTokenToGateway(gatewayURL: String, token: String) async -> Bool {
        guard let deviceToken, !deviceToken.isEmpty else { return false }
        let baseURL = gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !baseURL.isEmpty, !token.isEmpty else { return false }

        let deviceID = OpenClawClient().deviceID
        let message = "【推送注册】iOS 设备已注册远程推送。设备标识：\(deviceID)，APNs deviceToken：\(deviceToken)。请记录该 token；需要向本设备推送时使用。"
        do {
            _ = try await OpenClawClient().chat(
                messages: [Message(role: .user, content: message)],
                gatewayURL: baseURL,
                token: token,
                sessionKey: Self.pushSessionKey
            )
            lastReportError = nil
            logger.info("device token reported to gateway")
            return true
        } catch {
            lastReportError = error.localizedDescription
            LogCollector.record(module: "推送", "上报 deviceToken 失败：\(AppErrorText.localized(error.localizedDescription))")
            return false
        }
    }

    /// 官方对齐上报链：优先网关 RPC push.apns.register（探测支持才用），
    /// 其次 PushRelay 中继（配置了 relayBaseURL），最后降级 chat 消息上报。
    @discardableResult
    func reportDeviceTokenWithFallback(
        settings: SettingsStore,
        gatewayConnection: GatewayConnection? = nil
    ) async -> Bool {
        guard let deviceToken, !deviceToken.isEmpty else { return false }

        // 1) 网关 RPC（官方 NodeAppModel.push.apns.register）
        if let gatewayConnection {
            let supports = await gatewayConnection.supportsServerMethod("push.apns.register") ?? false
            if supports {
                do {
                    let deviceID = OpenClawClient().deviceID
                    let params: [String: AnyCodable] = [
                        "apnsToken": AnyCodable(deviceToken),
                        "deviceId": AnyCodable(deviceID),
                        "environment": AnyCodable(PushBuildConfig.load().environment.rawValue)
                    ]
                    _ = try await gatewayConnection.request(method: "push.apns.register", params: params, timeoutMs: 20)
                    lastReportError = nil
                    return true
                } catch {
                    lastReportError = error.localizedDescription
                    logger.error("push.apns.register failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // 2) PushRelay 中继（配置了 relayBaseURL 才走）
        let config = PushBuildConfig.load()
        if config.mode == .relay, let relayBase = config.relayBaseURL, !relayBase.isEmpty {
            let client = PushRelayClient(baseURL: relayBase)
            do {
                let response = try await client.register(PushRelayRegisterRequest(
                    deviceId: OpenClawClient().deviceID,
                    apnsToken: deviceToken,
                    gatewayURL: settings.settings.gatewayURL,
                    gatewayToken: settings.gatewayToken,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                    environment: config.environment.rawValue
                ))
                if response.ok == true {
                    lastReportError = nil
                    return true
                }
                lastReportError = response.error ?? "中继未确认"
            } catch {
                lastReportError = error.localizedDescription
                logger.error("relay register failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 3) 降级：chat 上报（原有行为）
        return await reportDeviceTokenToGateway(
            gatewayURL: settings.settings.gatewayURL,
            token: settings.gatewayToken
        )
    }

    /// 已配置网关时自动上报（供主智能体在拿到 token 后调用）。
    @discardableResult
    func reportIfConfigured(settings: SettingsStore) async -> Bool {
        guard settings.isConfigured else { return false }
        return await reportDeviceTokenWithFallback(settings: settings, gatewayConnection: nil)
    }
}