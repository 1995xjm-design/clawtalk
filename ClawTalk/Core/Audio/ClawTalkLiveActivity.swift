import ActivityKit
import Foundation

/// Live Activity（锁屏/灵动岛）数据模型：显示当前语音对话状态。
struct ClawTalkLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var statusText: String
    }

    var channelName: String
}

/// Live Activity（锁屏/灵动岛）控制器：开启 / 更新 / 结束。
/// 部署目标 iOS 17.0，ActivityKit 自 iOS 16.1 起可用；仍用 #available 保护，
/// 避免将来降低部署目标时编译报错。
@available(iOS 16.1, *)
enum ClawTalkLiveActivity {
    /// 开启 Live Activity（已有活动则直接更新文案，避免重复开启）。
    static func start(channelName: String, initialStatus: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let activity = Activity<ClawTalkLiveActivityAttributes>.activities.first {
            let content = ActivityContent(
                state: ClawTalkLiveActivityAttributes.ContentState(statusText: initialStatus),
                staleDate: nil
            )
            Task { await activity.update(content) }
            return
        }

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