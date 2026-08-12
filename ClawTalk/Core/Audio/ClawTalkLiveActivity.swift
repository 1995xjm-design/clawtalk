import ActivityKit
import Foundation

/// Live Activity（锁屏/灵动岛）控制器：开启 / 更新 / 结束。
/// 部署目标 iOS 17.0，ActivityKit 自 iOS 16.1 起可用；仍用 #available 保护，
/// 避免将来降低部署目标时编译报错。
///
/// 风格（简约/标准/详细）与「随 agent 切换」由设置页 AppSettings 控制：
/// - 每次更新时读取 AppSettings（UserDefaults "app_settings"），按 liveActivityStyle 组合文案；
/// - ContentState 目前只有 statusText 字段，风格差异通过文案排版体现；
///   如需真正的分风格视觉布局（字号/颜色/图标），需同步改 ClawTalkWidget 渲染（见接线说明）。
///
/// ⚠️ ActivityKit 限制：本 App 使用 pushType: nil（未配置 APNs 推送），
/// 本地 update 只在 App 进程存活期间可靠（前台或后台任务）；真正后台推送更新需网关 APNs 通道。
@available(iOS 16.1, *)
enum ClawTalkLiveActivity {
    /// 对话状态默认图标（详细风格前置）。
    private static let defaultIcon = "💬"

    /// 开启 Live Activity（已有对话活动则直接更新文案，避免重复开启；
    /// 已有「随时唤醒」活动则先结束再开启对话状态）。
    static func start(channelName: String, initialStatus: String, icon: String = ClawTalkLiveActivity.defaultIcon) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let composedText = Self.compose(
            channelName: channelName,
            icon: icon,
            status: initialStatus,
            style: currentStyle,
            isWake: channelName == wakeChannelName
        )

        if let activity = Activity<ClawTalkLiveActivityAttributes>.activities.first {
            if activity.attributes.channelName == wakeChannelName {
                Task {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    createActivity(channelName: channelName, initialStatus: composedText)
                }
                return
            }
            let content = ActivityContent(
                state: ClawTalkLiveActivityAttributes.ContentState(statusText: composedText),
                staleDate: nil
            )
            Task { await activity.update(content) }
            return
        }

        createActivity(channelName: channelName, initialStatus: composedText)
    }

    // MARK: - 随时唤醒状态（后台唤醒监听期间显示）

    /// 开启「随时唤醒」锁屏状态；已在显示对话状态时先结束对话活动再切换。
    /// 「随时唤醒」是固定卡片，不套用对话风格。
    static func startWakeListening() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let activity = Activity<ClawTalkLiveActivityAttributes>.activities.first {
            if activity.attributes.channelName == wakeChannelName {
                // 已显示「随时唤醒」，直接更新文案
                let content = ActivityContent(
                    state: ClawTalkLiveActivityAttributes.ContentState(statusText: wakeStatusText),
                    staleDate: nil
                )
                Task { await activity.update(content) }
                return
            }
            // 正在显示对话状态：先结束再切到「随时唤醒」
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
                createActivity(channelName: wakeChannelName, initialStatus: wakeStatusText)
            }
            return
        }
        createActivity(channelName: wakeChannelName, initialStatus: wakeStatusText)
    }

    /// 更新「随时唤醒」锁屏状态文案（固定卡片，原样显示）。
    static func updateWakeListening() {
        update(statusText: wakeStatusText)
    }

    /// 结束「随时唤醒」锁屏状态（不影响对话状态活动）。
    static func endWakeListening() {
        Task {
            for activity in Activity<ClawTalkLiveActivityAttributes>.activities
            where activity.attributes.channelName == wakeChannelName {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - 更新

    /// 更新锁屏状态文案。对话状态会按当前风格组合（频道名/图标 + 状态）；
    /// 「随时唤醒」固定卡片保持原样。
    static func update(statusText: String, icon: String = ClawTalkLiveActivity.defaultIcon) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let activity = Activity<ClawTalkLiveActivityAttributes>.activities.first else { return }
        let isWake = activity.attributes.channelName == wakeChannelName
        let composedText = Self.compose(
            channelName: activity.attributes.channelName,
            icon: icon,
            status: statusText,
            style: currentStyle,
            isWake: isWake
        )
        let content = ActivityContent(
            state: ClawTalkLiveActivityAttributes.ContentState(statusText: composedText),
            staleDate: nil
        )
        Task {
            await activity.update(content)
        }
    }

    /// 结束并移除所有 Live Activity。
    static func endAll() {
        Task {
            for activity in Activity<ClawTalkLiveActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - 随 agent 切换

    /// 频道/agent 切换时调用（由主智能体在频道切换处接线）：
    /// - 开启「随 agent 切换」且 agent 名变化：结束旧卡片并以新 agent 名重建
    ///   （attributes.channelName 创建后不可变，只能重建）；
    /// - 未开启或 agent 名未变：仅更新文案。
    static func updateForAgent(channelName: String, status: String, icon: String = ClawTalkLiveActivity.defaultIcon) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let activity = Activity<ClawTalkLiveActivityAttributes>.activities.first else {
            start(channelName: channelName, initialStatus: status, icon: icon)
            return
        }
        if activity.attributes.channelName == wakeChannelName {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
                start(channelName: channelName, initialStatus: status, icon: icon)
            }
            return
        }
        if followsAgent && activity.attributes.channelName != channelName {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
                start(channelName: channelName, initialStatus: status, icon: icon)
            }
            return
        }
        update(statusText: status, icon: icon)
    }

    // MARK: - 语音助手状态（语音大卡联动）

    private static let voiceAssistantChannelName = "ClawTalk·语音助手"

    /// 开启「语音助手」锁屏状态：优先复用/更新语音助手卡片；
    /// 若正在显示聊天/唤醒卡片，先结束再创建语音助手卡片，避免文案互相覆盖。
    static func startVoiceAssistant(status: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let activity = Activity<ClawTalkLiveActivityAttributes>.activities.first {
            if activity.attributes.channelName == voiceAssistantChannelName {
                let content = ActivityContent(
                    state: ClawTalkLiveActivityAttributes.ContentState(statusText: status),
                    staleDate: nil
                )
                Task { await activity.update(content) }
                return
            }
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
                createActivity(channelName: voiceAssistantChannelName, initialStatus: status)
            }
            return
        }
        createActivity(channelName: voiceAssistantChannelName, initialStatus: status)
    }

    /// 结束「语音助手」锁屏状态（只结束语音助手卡片开启的活动，不影响聊天/唤醒活动）。
    static func endVoiceAssistant() {
        Task {
            for activity in Activity<ClawTalkLiveActivityAttributes>.activities
            where activity.attributes.channelName == voiceAssistantChannelName {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
    // MARK: - 风格与设置

    /// 从设置读取当前灵动岛风格；读不到时回退「标准」。
    private static var currentStyle: LiveActivityStyle {
        loadSettings()?.liveActivityStyle ?? .standard
    }

    /// 是否开启「随 agent 切换」。
    private static var followsAgent: Bool {
        loadSettings()?.liveActivityFollowAgent ?? false
    }

    /// 与 SettingsStore.settingsKey（"app_settings"）保持一致。
    private static func loadSettings() -> AppSettings? {
        guard let data = UserDefaults.standard.data(forKey: "app_settings") else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    /// 按风格组合锁屏/灵动岛文案：
    /// - 简约：仅状态文字；
    /// - 标准：「频道名 · 状态」；
    /// - 详细：「图标 频道名」+「状态」两行。
    private static func compose(
        channelName: String,
        icon: String,
        status: String,
        style: LiveActivityStyle,
        isWake: Bool
    ) -> String {
        if isWake { return status }
        switch style {
        case .minimal:
            return status
        case .standard:
            return "\(channelName) · \(status)"
        case .detailed:
            return "\(icon) \(channelName)\n\(status)"
        }
    }

    private static let wakeChannelName = "ClawTalk·随时唤醒"
    private static let wakeStatusText = "随时唤醒·说你好小爪"

    private static func createActivity(channelName: String, initialStatus: String) {
        let attributes = ClawTalkLiveActivityAttributes(channelName: channelName)
        let content = ActivityContent(
            state: ClawTalkLiveActivityAttributes.ContentState(statusText: initialStatus),
            staleDate: nil
        )
        do {
            _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
        } catch {
            LogCollector.record(module: "锁屏状态", "Live Activity 启动失败：\(AppErrorText.localized(error.localizedDescription))")
        }
    }
}