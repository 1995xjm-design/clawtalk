import ActivityKit
import Foundation

/// Live Activity（锁屏/灵动岛）控制器：开启 / 更新 / 结束。
/// 部署目标 iOS 17.0，ActivityKit 自 iOS 16.1 起可用；仍用 #available 保护，
/// 避免将来降低部署目标时编译报错。
@available(iOS 16.1, *)
enum ClawTalkLiveActivity {
    /// 开启 Live Activity（已有对话活动则直接更新文案，避免重复开启；
    /// 已有「随时唤醒」活动则先结束再开启对话状态）。
    static func start(channelName: String, initialStatus: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let activity = Activity<ClawTalkLiveActivityAttributes>.activities.first {
            if activity.attributes.channelName == wakeChannelName {
                Task {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    createActivity(channelName: channelName, initialStatus: initialStatus)
                }
                return
            }
            let content = ActivityContent(
                state: ClawTalkLiveActivityAttributes.ContentState(statusText: initialStatus),
                staleDate: nil
            )
            Task { await activity.update(content) }
            return
        }

        createActivity(channelName: channelName, initialStatus: initialStatus)
    }

    // MARK: - 随时唤醒状态（后台唤醒监听期间显示）

    /// 开启「随时唤醒」锁屏状态；已在显示对话状态时先结束对话活动再切换。
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

    /// 更新「随时唤醒」锁屏状态文案。
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

    /// 更新锁屏状态文案。
    static func update(statusText: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let activity = Activity<ClawTalkLiveActivityAttributes>.activities.first else { return }
        let content = ActivityContent(
            state: ClawTalkLiveActivityAttributes.ContentState(statusText: statusText),
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
}