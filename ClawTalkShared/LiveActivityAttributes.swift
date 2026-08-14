/// Live Activity（锁屏/灵动岛）卡片风格：简约/标准/详细（App 与 Widget 共享）。
enum LiveActivityStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case minimal = "简约"
    case standard = "标准"
    case detailed = "详细"

    /// 兼容旧数据：未知值回退到「标准」。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LiveActivityStyle(rawValue: raw) ?? .standard
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal: return "简约"
        case .standard: return "标准"
        case .detailed: return "详细"
        }
    }
}

import ActivityKit
import Foundation

/// Live Activity（锁屏/灵动岛）数据模型：显示当前语音对话状态。
/// 该类型需被主 App 与 ClawTalkWidget 扩展两个 target 共同编译（从 ClawTalkLiveActivity.swift 原样搬移）。
struct ClawTalkLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var statusText: String
        /// 卡片风格（LiveActivityStyle.rawValue）；旧活动实例无此字段时为 nil。
        var style: String?
        /// 进度（0-1，标准/详细档显示进度条）；旧活动实例无此字段时为 nil。
        var progress: Double? = nil
    }

    var channelName: String
}
