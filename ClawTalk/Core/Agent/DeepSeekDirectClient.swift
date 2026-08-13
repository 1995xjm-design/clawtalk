import Foundation

/// 直连 DeepSeek 用的对话消息（OpenAI 兼容 chat/completions 的 {role, content}）。
struct DeepSeekChatMessage: Codable {
    let role: String
    let content: String

    /// 从 ClawTalk 会话消息映射（图片/文件附件不支持直连模式，仅取文本）。
    static func from(_ message: Message) -> DeepSeekChatMessage? {
        switch message.role {
        case .user:
            return DeepSeekChatMessage(role: "user", content: message.content)
        case .assistant:
            return DeepSeekChatMessage(role: "assistant", content: message.content)
        }
    }
}

/// DeepSeek API 客户端（OpenAI 兼容 /v1/chat/completions）。
/// - Key 从 SecureStorage 读取（键 `deepseek_api_key`，与设置页「语音助手通道 → DeepSeek Key」一致）
/// - 支持一次性与流式；Key 缺失 / HTTP 错误 / 空响应均给出诚实中文报错
final class DeepSeekDirectClient {
    static let shared = DeepSeekDirectClient()

    /// DeepSeek Key 在 Keychain 中的键名。
    static let apiKeyKey = "deepseek_api_key"
    /// 端点（官方 OpenAI 兼容端点；代理/自建可覆盖）。
    static var endpoint = "https://api.deepseek.com/v1/chat/completions"
    /// 单次请求超时（秒）。
    static var timeout: TimeInterval = 60

    enum DeepSeekError: LocalizedError {
        case missingAPIKey
        case badResponse(Int, String)
        case emptyReply
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "未配置 DeepSeek API Key：请到 设置 → 语音助手通道 填写。"
            case .badResponse(let code, let body):
                return "DeepSeek 请求失败（\(code)）：\(Self.friendlyHTTPText(code: code, body: body))"
            case .emptyReply:
                return "DeepSeek 没有返回内容，请重试或换个说法。"
            case .invalidResponse:
                return "DeepSeek 返回了无法解析的响应。"
            }
        }

        private static func friendlyHTTPText(code: Int, body: String) -> String {
            switch code {
            case 401: return "API Key 无效或已过期"
            case 402: return "账户余额不足"
            case 429: return "请求过于频繁，请稍后重试"
            case 500, 502, 503: return "DeepSeek 服务暂时不可用"
            default: return String(body.prefix(120))
            }
        }
    }

    private init() {}

    /// 当前 Key（nil = 未配置）。
    var apiKey: String? {
        SecureStorage.shared.getString(Self.apiKeyKey)
    }

    /// 一次性调用：返回完整回复文本（内部走流式累积，失败抛 DeepSeekError）。
    func complete(
        messages: [DeepSeekChatMessage],
        system: String?,
        model: String = "deepseek-chat"
    ) async throws -> String {
        var all = ""
        for try await delta in stream(messages: messages, system: system, model: model) {
            all += delta
        }
        let trimmed = all.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeepSeekError.emptyReply }
        return trimmed
    }

    /// 流式调用：逐段吐出回复文本。
    func stream(
        messages: [DeepSeekChatMessage],
        system: String?,
        model: String = "deepseek-chat"
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = apiKey, !key.isEmpty else {
                        throw DeepSeekError.missingAPIKey
                    }

                    var chatMessages: [[String: String]] = []
                    if let system, !system.isEmpty {
                        chatMessages.append(["role": "system", "content": system])
                    }
                    chatMessages += messages.map { ["role": $0.role, "content": $0.content] }

                    let payload: [String: Any] = [
                        "model": model,
                        "messages": chatMessages,
                        "stream": true
                    ]
                    guard let url = URL(string: Self.endpoint) else {
                        throw DeepSeekError.invalidResponse
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = Self.timeout
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await byte in bytes {
                            body.append(String(decoding: [byte], as: UTF8.self))
                            if body.count > 300 { break }
                        }
                        throw DeepSeekError.badResponse(http.statusCode, body)
                    }

                    // 逐字节缓冲，按换行切 SSE 行（整行解码，避免多字节中文被截断）。
                    var rawBuffer = Data()
                    for try await byte in bytes {
                        rawBuffer.append(byte)
                        while let nl = rawBuffer.firstIndex(of: 0x0A) {
                            let lineData = rawBuffer.subdata(in: rawBuffer.startIndex..<nl)
                            rawBuffer.removeSubrange(rawBuffer.startIndex...nl)
                            let line = String(decoding: lineData, as: UTF8.self)
                                .trimmingCharacters(in: .whitespaces)
                            guard line.hasPrefix("data:") else { continue }
                            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            guard !data.isEmpty, data != "[DONE]" else { continue }
                            guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                                  let choices = object["choices"] as? [[String: Any]],
                                  let delta = choices.first?["delta"] as? [String: Any],
                                  let content = delta["content"] as? String,
                                  !content.isEmpty else { continue }
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 记忆注入：把本地档案摘要 + 电脑同步快照 + 最近对话拼成 system prompt。
/// 诚实原则：没有档案/快照时只给任务说明，不编造记忆。
enum MemoryPromptBuilder {
    static func build(
        profiles: [MemoryProfile],
        computerSummary: String?,
        dialogueSnippet: [String],
        recentDialogue: [String],
        purpose: String
    ) -> String {
        var parts: [String] = []
        parts.append("你是 ClawTalk 的本地智能助手。当前任务：\(purpose)。请用自然的中文回答，简洁口语化。")

        if !profiles.isEmpty {
            let lines = profiles.prefix(20).map {
                "【\($0.category.rawValue)】\($0.summary)（来源：\($0.source)）"
            }
            parts.append("关于用户的本地档案：\n" + lines.joined(separator: "\n"))
        }
        if let computerSummary, !computerSummary.isEmpty {
            parts.append("电脑端同步的记忆摘要：\n" + computerSummary)
        }
        if !dialogueSnippet.isEmpty {
            parts.append("最近对话片段：\n" + dialogueSnippet.prefix(10).joined(separator: "\n"))
        }
        if !recentDialogue.isEmpty {
            parts.append("本次会话上下文：\n" + recentDialogue.suffix(10).joined(separator: "\n"))
        }
        parts.append("不要编造档案或快照里没有的事实；信息不足时直接说明。")
        return parts.joined(separator: "\n\n")
    }
}
