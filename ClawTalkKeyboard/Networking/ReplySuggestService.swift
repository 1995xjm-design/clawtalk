import Foundation

/// 回复候选服务：POST {gateway}/api/reply-suggest。
/// 请求失败（未配置/网络/HTTP/解析）时降级返回本地中文恋爱回复模板兜底列表，
/// 保证键盘离线/网关异常时仍有可用候选，不阻塞输入。
final class ReplySuggestService {

    /// 生成回复候选。contact 可为 nil（未选择对象）；style 可选。
    /// - Parameters:
    ///   - contact: 选中的聊天对象，nil 表示未选择
    ///   - text: 对方说的话（可含上下文）
    ///   - style: 可选风格参数（如"温柔"），nil 表示由服务端决定
    ///   - count: 期望候选条数（传给服务端；失败兜底返回完整本地模板列表）
    static func suggestReplies(
        contact: ChatContact?,
        text: String,
        style: String?,
        count: Int
    ) async -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return fallbackReplies }

        let config = SharedConfig.load()
        guard !config.isEmpty else { return fallbackReplies }

        do {
            let suggestions = try await OpenClawReplyClient.generateSuggestions(
                text: trimmedText,
                contact: contact,
                style: style,
                count: count,
                config: config
            )
            guard !suggestions.isEmpty else { return fallbackReplies }
            return count > 0 ? Array(suggestions.prefix(count)) : suggestions
        } catch {
            KeyboardLogCollector.record(module: "键盘回复", "网关回复失败：\(error.localizedDescription)")
            return fallbackReplies
        }
    }

    /// 本地中文恋爱回复模板兜底（≥8 条，离线/网关异常时使用）
    private static let fallbackReplies: [String] = [
        "早上好，今天也要开心哦",
        "想你了，你在干嘛",
        "吃饭了吗？记得按时吃饭",
        "天冷了，多穿点衣服",
        "别太累了，我会心疼的",
        "有你在，我做什么都开心",
        "晚安，好梦，梦里也要有我",
        "不管发生什么，我都陪着你",
        "今天也要元气满满呀",
        "这么巧，我也刚好在想你"
    ]
}
