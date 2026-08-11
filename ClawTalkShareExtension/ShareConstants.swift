import Foundation

/// 分享扩展与主 App 的 App Group 共享契约。
/// 描述文件允许的 App Group 为 group.7518554；主 App 侧写入/读取需保持同一组。
enum ShareAppGroup {
    static let suiteName = "group.7518554"
    static let containerID = "group.7518554"

    /// 主 App 启动时写入的频道列表（JSON 数组：[ShareChannel]）
    static let channelsKey = "channels_list"
    /// 分享扩展写入的待发消息（JSON: PendingShareMessage）
    static let pendingMessageKey = "pending_share_message"
    /// 待发标记（Bool；主 App 处理完待发消息后清除）
    static let pendingFlagKey = "pending_share_flag"
    /// 附件落盘目录（App Group container/ShareUploads/）
    static let attachmentsDirName = "ShareUploads"
}

/// 频道轻量模型：与主 App Channel 的 id/name 字段对齐（id 为 UUID 字符串时可直接解码）。
struct ShareChannel: Identifiable, Codable {
    let id: String
    var name: String
    var agentId: String?
}

/// 附件：文件已复制进 App Group 容器，containerPath 为容器内绝对路径。
struct PendingShareAttachment: Codable {
    var fileName: String
    var containerPath: String
    var mimeType: String
}

/// 待发消息：主 App 轮询 pending_share_flag 后读取并发送。
struct PendingShareMessage: Codable {
    var channelId: String
    var channelName: String
    var text: String
    var attachments: [PendingShareAttachment]
    var createdAt: TimeInterval
}