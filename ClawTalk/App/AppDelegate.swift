import UIKit

/// APNs 回调转发到 PushManager（接线 A：ClawTalkApp 通过 UIApplicationDelegateAdaptor 接入）。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 崩溃捕获：Objective-C 异常 + 常见信号（SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP），
    /// 崩溃瞬间把堆栈写入 LogCollector，下次打开「日志与诊断」即可看到根因。
    private static var crashHandlerInstalled = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.installCrashHandler()
        return true
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
