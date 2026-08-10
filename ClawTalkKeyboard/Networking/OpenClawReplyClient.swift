import Foundation
import os.log

private let logger = Logger(subsystem: "com.openclaw.clawtalk.keyboard", category: "network")

/// 键盘扩展的 OpenClaw 网关连接层。
///
/// 仿 ClawTalk 主 App 的 OpenClawClient.chat()：非流式
/// POST {gateway}/v1/chat/completions，Bearer token，
/// model "openclaw:<agentId>"，返回单条回复文本。
/// 把"选中对象 + 输入文本"发给 OpenClaw（记忆引擎 + 数字孪生推演）生成回复。
final class OpenClawReplyClient {

    /// 键盘扩展可复用的会话（TLS 1.2 起）
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config)
    }()

    /// 生成一条回复。config 未配置、网络失败或网关无内容时抛错。
    /// - Parameters:
    ///   - text: 对方发来的消息（可含上下文）
    ///   - contact: 选中的聊天对象，nil 表示未选择
    ///   - style: 可选回复风格，如"温柔""幽默"
    ///   - config: App Group 读取的网关配置
    ///   - sessionKey: 可选 x-openclaw-session-key（沿用主 App 会话时传）
    ///   - messageChannel: 可选 x-openclaw-message-channel
    static func generateReply(
        text: String,
        contact: ChatContact?,
        style: String?,
        count: Int = 1,
        config: SharedConfig,
        sessionKey: String? = nil,
        messageChannel: String? = nil
    ) async throws -> String {
        guard !config.isEmpty else {
            throw GatewayAPIError.notConfigured
        }

        var request = try makeRequest(config: config, sessionKey: sessionKey, messageChannel: messageChannel)
        request.timeoutInterval = 60

        let body = ChatCompletionRequestBody(
            model: "openclaw:\(config.agentId)",
            messages: makeMessages(text: text, contact: contact, style: style, count: count),
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)
        if let size = request.httpBody?.count {
            logger.info("Reply request body: \(size) bytes")
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GatewayAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw GatewayAPIError.httpError(http.statusCode, String(preview))
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponseBody.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayAPIError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 生成 N 条候选回复（每行一条），供键盘候选栏使用。
    static func generateSuggestions(
        text: String,
        contact: ChatContact?,
        style: String?,
        count: Int,
        config: SharedConfig,
        sessionKey: String? = nil
    ) async throws -> [String] {
        let content = try await generateReply(
            text: text,
            contact: contact,
            style: style,
            count: count,
            config: config,
            sessionKey: sessionKey
        )
        var lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        lines = lines.map { line in
            line
                .replacingOccurrences(of: #"^\d+[.、)]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[-–—•]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleaned = lines.filter { !$0.isEmpty }
        return cleaned.isEmpty ? [content] : cleaned
    }

    // MARK: - 私有构建

    private static func makeRequest(
        config: SharedConfig,
        sessionKey: String?,
        messageChannel: String?
    ) throws -> URLRequest {
        let baseURL = config.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw GatewayAPIError.invalidURL
        }
        try GatewaySecurity.validate(url)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let sessionKey {
            request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
        }
        if let messageChannel {
            request.setValue(messageChannel, forHTTPHeaderField: "x-openclaw-message-channel")
        }
        return request
    }

    /// 组装 system + user 消息：把选中对象画像与输入文本交给网关侧记忆引擎/数字孪生推演
    private static func makeMessages(
        text: String,
        contact: ChatContact?,
        style: String?,
        count: Int = 1
    ) -> [ChatCompletionRequestBody.Message] {
        var systemLines = [
            "你是 ClawTalk 的 AI 回复助手，正在帮用户回复聊天消息。",
            "请结合你记忆中对用户与该联系人的了解（记忆引擎 + 数字孪生推演），生成一条自然、贴切的回复。",
            count > 1
                ? "请生成 \(count) 条候选回复，每行一条，只输出回复内容本身，不要编号、不要前缀、不要引号或多余标点。"
                : "只输出回复内容本身，不要解释、前缀、引号或多余标点。"
        ]
        if let contact {
            systemLines.append("对方：\(contact.name)（画像完整度 \(scoreText(contact.profileScore))）")
        }
        if let style, !style.isEmpty {
            systemLines.append("回复风格：\(style)")
        }
        let userContent = "对方发来：\(text)\n请帮我回复一条。"
        return [
            .init(role: "system", content: systemLines.joined(separator: "\n")),
            .init(role: "user", content: userContent)
        ]
    }

    /// 画像完整度展示：整数不补 .0，其余保留原样（如 87 / 0.8 / 0.75）
    private static func scoreText(_ score: Double) -> String {
        if score == score.rounded() {
            return String(Int(score))
        }
        return String(score)
    }
}

// MARK: - 请求/响应体（对齐 OpenAI Chat Completions 格式）

private struct ChatCompletionRequestBody: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatCompletionResponseBody: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ResponseMessage
    }

    struct ResponseMessage: Decodable {
        let content: String?
    }
}

// MARK: - 共享错误类型（键盘扩展自用，等价主 App 的 OpenClawError）

enum GatewayAPIError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case emptyResponse
    case insecureConnection

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "网关未配置，请先在 ClawTalk 中完成设置。"
        case .invalidURL:
            return "网关地址无效。"
        case .invalidResponse:
            return "网关响应无效。"
        case .httpError(let code, let body):
            return "网关返回 HTTP \(code)：\(body.prefix(200))"
        case .emptyResponse:
            return "网关没有返回回复内容。"
        case .insecureConnection:
            return "网关需要 HTTPS（本机/内网地址可例外）。"
        }
    }
}

// MARK: - 共享安全校验（公网强制 HTTPS，本机/内网允许 HTTP 联调）

enum GatewaySecurity {
    static func validate(_ url: URL) throws {
        if url.scheme == "https" { return }
        guard url.scheme == "http", let host = url.host?.lowercased() else {
            throw GatewayAPIError.insecureConnection
        }
        // 允许 HTTP 的本机/内网地址
        if host == "localhost" || host == "127.0.0.1" || host == "::1"
            || host.hasSuffix(".local")
            || host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
            || host.hasPrefix("172.16.") || host.hasPrefix("172.17.") || host.hasPrefix("172.18.")
            || host.hasPrefix("172.19.") || host.hasPrefix("172.2") || host.hasPrefix("172.3")
        {
            return
        }
        throw GatewayAPIError.insecureConnection
    }
}