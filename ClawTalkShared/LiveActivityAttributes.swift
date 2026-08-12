import ActivityKit
import Foundation

/// Live Activity（锁屏/灵动岛）数据模型：显示当前语音对话状态。
/// 该类型需被主 App 与 ClawTalkWidget 扩展两个 target 共同编译（从 ClawTalkLiveActivity.swift 原样搬移）。
struct ClawTalkLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var statusText: String
        /// 卡片风格（LiveActivityStyle.rawValue）；旧活动实例无此字段时为 nil。
        var style: String?
    }

    var channelName: String
}
