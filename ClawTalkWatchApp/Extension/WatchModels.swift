import Foundation

/// 手表端频道模型：字段与主 App 写入 App Group 的 channels_list
/// （ClawTalkApp.ShareChannelEntry：id/name/agentId）保持一致，可直接解码。
struct WatchChannel: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var agentId: String?
}

/// 手表端消息模型：经 WatchConnectivity 与 iPhone 主 App 交换（第一版仅文本）。
/// 解码用 JSONDecoder 默认策略（Date = secondsSinceReferenceDate 的 Double，
/// UUID = 字符串），与主 App 侧 Message 编码保持一致。
struct WatchMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: String
    let content: String
    let timestamp: Date
    var channelName: String

    init(id: UUID = UUID(), role: String, content: String, timestamp: Date = Date(), channelName: String = "") {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.channelName = channelName
    }

    var isUser: Bool {
        role == "user"
    }
}