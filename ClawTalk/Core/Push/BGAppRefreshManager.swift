import Foundation
import BackgroundTasks
import OSLog
import Observation

/// 后台应用刷新（BGAppRefreshTask）：
/// - 注册 90 秒后台刷新任务（系统实际调度可能按功耗策略延后到 15 分钟以上，属系统行为）
/// - 后台短连网关拉取专用会话新消息，有新消息则发本地通知（复用 NotificationCapability）
///
/// 接线（由主智能体在 ClawTalkApp 完成）：
/// 1. Info.plist 的 BGTaskSchedulerPermittedIdentifiers 加入 "com.openclaw.clawtalk.bgrefresh"
/// 2. UIBackgroundModes 加入 "fetch"
/// 3. 启动时调用 BGAppRefreshManager.shared.register()；进入后台时调用 scheduleRefresh()
@MainActor
@Observable
final class BGAppRefreshManager {
    static let shared = BGAppRefreshManager()

    /// 必须与 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 保持一致
    static let taskIdentifier = "com.openclaw.clawtalk.bgrefresh"

    private let logger = Logger(subsystem: "com.openclaw.clawtalk", category: "bg-refresh")
    private let defaults = UserDefaults.standard
    private let lastSeenKeyPrefix = "bg_refresh_last_seen_"

    private(set) var lastRefreshResult: String?
    private(set) var lastRefreshDate: Date?

    private init() {}

    // MARK: - 注册与调度

    /// 启动时调用一次（尽早注册，系统要求 App 启动早期完成注册）。
    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil,
            launchHandler: { [weak self] task in
                guard let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in
                    await self?.handleAppRefresh(task: refreshTask)
                }
            }
        )
        logger.info("BGAppRefreshTask registered")
    }

    /// 请求下一次刷新（默认最早 90 秒后；系统可能按功耗策略延后）。
    func scheduleRefresh(earliestBeginInSeconds: TimeInterval = 90) {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestBeginInSeconds)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("BGAppRefreshTask scheduled")
        } catch {
            logger.error("BGAppRefreshTask schedule failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 执行

    private func handleAppRefresh(task: BGAppRefreshTask) async {
        task.expirationHandler = {
            // 系统到期兜底：不额外处理，任务以已执行内容为准
        }
        _ = await checkForNewMessages()
        task.setTaskCompleted(success: true)
        // 无论成败，为下一轮安排刷新
        scheduleRefresh()
    }

    /// 短连网关拉取专用会话新消息；返回新消息条数（未配置/失败返回 0）。
    /// 同时供静默推送调用（PushManager.handleRemoteNotification）。
    @discardableResult
    func checkForNewMessages() async -> Int {
        lastRefreshDate = Date()

        let store = SettingsStore()
        guard store.isConfigured, store.settings.useWebSocket,
              let wsURL = URL(string: store.settings.resolvedWebSocketURL)
        else {
            lastRefreshResult = "未配置网关或未开启 WebSocket，跳过"
            return 0
        }

        let sessionKey = PushManager.pushSessionKey
        let lastSeenKey = lastSeenKeyPrefix + sessionKey
        let gateway = GatewayWebSocket(url: wsURL, token: store.gatewayToken)

        do {
            try await gateway.connect()
            let payload: ChatHistoryPayload = try await gateway.requestDecoded(
                method: "chat.history",
                params: ["sessionKey": AnyCodable(sessionKey), "limit": AnyCodable(30)]
            )
            await gateway.shutdown()

            let messages = payload.messages ?? []
            let latestTimestamp = messages.compactMap { $0.timestamp }.max() ?? 0
            let lastSeen = defaults.integer(forKey: lastSeenKey)

            if lastSeen == 0 {
                // 首次运行：只建立基线，不误报历史消息
                defaults.set(latestTimestamp, forKey: lastSeenKey)
                lastRefreshResult = "已建立消息基线"
                return 0
            }

            let newMessages = messages.filter { ($0.timestamp ?? 0) > lastSeen }
            if !newMessages.isEmpty {
                let count = newMessages.count
                try? await NotificationCapability.notify(
                    title: "ClawTalk · 网关新消息",
                    body: "网关会话有 \(count) 条新消息",
                    sound: nil,
                    priority: "urgent"
                )
                lastRefreshResult = "发现 \(count) 条新消息"
            } else {
                lastRefreshResult = "无新消息"
            }
            defaults.set(latestTimestamp, forKey: lastSeenKey)
            return newMessages.count
        } catch {
            lastRefreshResult = "拉取失败：\(error.localizedDescription)"
            logger.error("拉取网关消息失败: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}