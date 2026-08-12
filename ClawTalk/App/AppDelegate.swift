import UIKit
import WatchConnectivity

/// APNs 回调转发到 PushManager（接线 A：ClawTalkApp 通过 UIApplicationDelegateAdaptor 接入）。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, WCSessionDelegate {

    /// 崩溃捕获：Objective-C 异常 + 常见信号（SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP），
    /// 崩溃瞬间把堆栈写入 LogCollector，下次打开「日志与诊断」即可看到根因。
    private static var crashHandlerInstalled = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.installCrashHandler()
        // 手表接线（G1 基础版）：激活 WCSession，接收 watch 端消息。
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
        return true
    }

    // MARK: - WCSessionDelegate（手表 → 手机）

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            LogCollector.record(module: "手表", "WCSession 激活失败：\(AppErrorText.localized(error.localizedDescription))")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            if let text = message["text"] as? String, !text.isEmpty {
                NotificationCenter.default.post(
                    name: .clawTalkWatchTextReceived,
                    object: nil,
                    userInfo: ["text": text]
                )
            }
            if let word = message["wake"] as? String {
                NotificationCenter.default.post(name: .clawTalkWakeWordDetected, object: nil, userInfo: ["word": word])
            }
            replyHandler(["ok": true])
        }
    }

    private static func installCrashHandler() {
        guard !crashHandlerInstalled else { return }
        crashHandlerInstalled = true

        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(30).joined(separator: "\n")
            let name = exception.name.rawValue
            let reason = exception.reason ?? ""
            LogCollector.record(module: "崩溃", "NSException \(name): \(reason)\n\(stack)")
        }

        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for sig in signals {
            signal(sig) { s in
                let names: [Int32: String] = [
                    SIGABRT: "SIGABRT", SIGSEGV: "SIGSEGV", SIGBUS: "SIGBUS",
                    SIGILL: "SIGILL", SIGFPE: "SIGFPE", SIGTRAP: "SIGTRAP",
                ]
                let name = names[s] ?? "信号\(s)"
                let stack = Thread.callStackSymbols.prefix(30).joined(separator: "\n")
                LogCollector.record(module: "崩溃", "\(name) 崩溃\n\(stack)")
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }


    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushManager.shared.handleDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushManager.shared.handleRegistrationFailure(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        PushManager.shared.handleRemoteNotification(userInfo: userInfo)
        completionHandler(.newData)
    }
}
