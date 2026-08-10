import Foundation

/// 指令专用频道：把 App 发往 OpenClaw 的指令/日志发送到固定会话，可在频道列表查看与追问。
enum InstructionChannels {
    /// 日志诊断会话 key
    static let diagnostics = "agent:main:clawtalk-user:diag"
    /// 微信 Claw Bot 绑定会话 key
    static let wechatBind = "agent:main:clawtalk-user:wechat-bind"
    /// 文件传输助手会话 key
    static let fileTransfer = "agent:main:clawtalk-user:file-transfer"

    /// 查找或创建绑定固定会话 key 的频道，返回频道（供提示使用）
    @discardableResult
    static func ensureChannel(name: String, systemEmoji: String, sessionKey: String) -> Channel {
        if let existing = ChannelStore.shared.channels.first(where: { $0.serverSessionKey == sessionKey }) {
            return existing
        }
        var channel = Channel(name: name, agentId: "main", systemEmoji: systemEmoji)
        channel.serverSessionKey = sessionKey
        ChannelStore.shared.add(channel)
        return channel
    }
}
