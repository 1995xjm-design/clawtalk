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

        let baseURL = config.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/api/reply-suggest") else {
            return fallbackReplies
        }
        do {
            try GatewaySecurity.validate(url)
        } catch {
            return fallbackReplies
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body = ReplySuggestRequestBody(
            contactID: contact?.id,
            text: trimmedText,
            count: count,
            style: style
        )
        guard let bodyData = try? JSONEncoder().encode(body) else {
            return fallbackReplies
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return fallbackReplies
            }

            let decoded = try JSONDecoder().decode(ReplySuggestResponse.self, from: data)
            let suggestions = decoded.suggestions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !suggestions.isEmpty else { return fallbackReplies }
            if count > 0, suggestions.count > count {
                return Array(suggestions.prefix(count))
            }
            return suggestions
        } catch {
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

private struct ReplySuggestRequestBody: Encodable {
    let contactID: String?
    let text: String
    let count: Int
    let style: String?

    enum CodingKeys: String, CodingKey {
        case contactID = "contact_id"
        case text
        case count
        case style
    }
}

private struct ReplySuggestResponse: Decodable {
    let suggestions: [String]
}