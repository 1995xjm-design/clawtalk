import Foundation

/// 整理结果：note 为整理好的文档（未落库）+ 诚实来源信息。
struct DictationOrganizationResult {
    let note: DictationNote
    /// true = 本地规则降级（AI 未接入 / 调用失败 / 输出无法解析）
    let usedFallback: Bool
    /// 降级原因（展示给用户，诚实说明为什么没用 AI）
    let fallbackReason: String?
    /// AI 调用原始错误（仅记录日志用）
    let aiError: Error?
}

/// 口述文档整理逻辑，两条路：
/// ① 网关可用时调 OpenClawClient.stream（与 VoiceAssistantViewModel.requestAgentReplyViaGateway
///    同独立发送链路），让 agent 把口述整理成 JSON 文档（title/paragraphs/keyPoints）；
/// ② 网关不可用 / 调用失败 / AI 输出不是标准 JSON → 本地规则降级，
///    结果带 `organizedByAI = false`，UI 诚实标注「本地整理（未接 AI）」。
struct DictationOrganizer {

    /// 默认模型：跟随默认频道 agent，兜底 "main"（与 MeetingOrganizer 同策略）。
    static func defaultAgentID(settings: SettingsStore) -> String {
        if let wakeChannelID = settings.settings.voiceWakeChannelID,
           let matched = ChannelStore.shared.channels.first(where: { $0.id.uuidString == wakeChannelID }) {
            return matched.agentId
        }
        if let first = ChannelStore.shared.channels.first {
            return first.agentId
        }
        return "main"
    }

    static func organize(
        transcript: String,
        title: String?,
        date: Date,
        settings: SettingsStore
    ) async -> DictationOrganizationResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = DictationLocalOrganizer.makeNote(
            transcript: trimmed,
            title: title,
            date: date
        )

        guard !trimmed.isEmpty else {
            return DictationOrganizationResult(
                note: fallback,
                usedFallback: true,
                fallbackReason: "没有可整理的转写内容",
                aiError: nil
            )
        }

        // ① 网关不可用 → 诚实降级（不假装调用 AI）
        guard settings.isConfigured else {
            return DictationOrganizationResult(
                note: fallback,
                usedFallback: true,
                fallbackReason: "未配置 OpenClaw 网关",
                aiError: nil
            )
        }

        do {
            let raw = try await requestAIReply(transcript: trimmed, settings: settings)
            if let draft = DictationJSONParser.parse(raw) {
                // 字段缺失时用本地规则结果补齐（与 MeetingOrganizer 同策略），不硬编
                let paragraphs = draft.paragraphs.isEmpty ? fallback.paragraphs : draft.paragraphs
                let note = DictationNote(
                    date: date,
                    title: draft.title.isEmpty ? fallback.title : draft.title,
                    content: paragraphs.joined(separator: "\n\n"),
                    paragraphs: paragraphs,
                    keyPoints: draft.keyPoints,
                    organizedByAI: true,
                    rawTranscript: trimmed
                )
                return DictationOrganizationResult(note: note, usedFallback: false, fallbackReason: nil, aiError: nil)
            }
            // AI 返回了内容但解析不出标准 JSON → 诚实降级，不硬编
            return DictationOrganizationResult(
                note: fallback,
                usedFallback: true,
                fallbackReason: "AI 返回内容无法解析成文档",
                aiError: nil
            )
        } catch {
            // 网络失败 / 超时 / 空回复 → 诚实降级
            return DictationOrganizationResult(
                note: fallback,
                usedFallback: true,
                fallbackReason: "AI 整理失败（\(Self.friendlyError(error))）",
                aiError: error
            )
        }
    }

    // MARK: - AI 独立发送链路

    /// 与 VoiceAssistantViewModel.requestAgentReplyViaGateway 同模式：
    /// OpenClawClient.stream 流式累积回复，90 秒超时兜底。
    private static func requestAIReply(transcript: String, settings: SettingsStore) async throws -> String {
        let token = OpenClawClient.resolveHTTPToken(
            settingsToken: settings.gatewayToken,
            gatewayURL: settings.settings.gatewayURL
        )

        let prompt = Self.aiPrompt(transcript: transcript)
        let eventStream = OpenClawClient().stream(
            messages: [Message(role: .user, content: prompt)],
            gatewayURL: settings.settings.gatewayURL,
            token: token,
            model: "openclaw:\(defaultAgentID(settings: settings))",
            apiMode: settings.settings.agentAPIMode,
            sessionKey: nil,
            messageChannel: "webchat"
        )

        var reply = ""
        let deadline = Date().addingTimeInterval(90)
        do {
            for try await event in eventStream {
                try Task.checkCancellation()
                if Date() > deadline {
                    throw DictationOrganizeError.timeout
                }
                switch event {
                case .textDelta(let delta):
                    reply += delta
                case .modelIdentified, .completed:
                    break
                }
            }
        } catch {
            throw error
        }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DictationOrganizeError.emptyReply
        }
        return trimmed
    }

    /// AI 提示词：要求只输出 JSON，字段与文档结构对齐，禁止编造。
    /// 转写超长时截断到 8000 字再送 AI（原始全文仍完整保存在 rawTranscript，不丢内容）。
    private static func aiPrompt(transcript: String) -> String {
        let capped = transcript.count > 8000 ? String(transcript.prefix(8000)) + "…（后续内容省略）" : transcript
        return """
        你是文档整理助手。请把下面的口述转写整理成一篇结构化的文档，只输出一个 JSON 对象，不要输出任何其他文字、解释或 Markdown 代码块标记。

        输出格式（严格按此结构）：
        {
          "title": "文档标题（一句话概括，20 字以内）",
          "paragraphs": ["第一段", "第二段"],
          "keyPoints": ["要点一", "要点二"]
        }

        规则：
        - 只输出 JSON，禁止在 JSON 前后添加说明文字。
        - paragraphs 按逻辑分段：每个数组元素是一段完整内容，保留原意，不要编造原文没有的信息。
        - keyPoints 只提取原文里明确强调的重点；没有明确重点就用空数组，不要编造。

        口述转写内容：
        \(capped)
        """
    }

    private static func friendlyError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let msg = localized.errorDescription {
            return msg
        }
        return error.localizedDescription
    }
}

/// 口述整理专属错误。
enum DictationOrganizeError: LocalizedError {
    case timeout
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .timeout: return "等待 AI 回复超时"
        case .emptyReply: return "AI 没有返回内容"
        }
    }
}

/// 本地规则降级整理（诚实兜底，不造假）：
/// 按句号/换行切分句子，首句作标题，其余按长度合并成段落；
/// 含「重点/关键是/记住/注意」等强调词的句子额外提取为要点（保留原句，不改写）。
enum DictationLocalOrganizer {

    private static let keyPointKeywords = ["重点", "关键是", "记住", "注意", "切记", "最重要的是", "特别提醒", "别忘了"]
    /// 段落目标长度（字符）：优先保持句子完整，尽量让每段落在该长度左右。
    private static let targetParagraphLength = 100

    static func makeNote(transcript: String, title: String?, date: Date) -> DictationNote {
        let sentences = splitSentences(transcript)
        let paragraphs = buildParagraphs(from: sentences)
        let keyPoints = extractKeyPoints(from: sentences)
        let resolvedTitle = resolveTitle(title, firstSentence: sentences.first, date: date)

        return DictationNote(
            date: date,
            title: resolvedTitle,
            content: paragraphs.joined(separator: "\n\n"),
            paragraphs: paragraphs,
            keyPoints: keyPoints,
            organizedByAI: false,
            rawTranscript: transcript
        )
    }

    /// 按中英文句末标点切分（句号/问号/感叹号/分号/换行）。
    private static func splitSentences(_ transcript: String) -> [String] {
        let normalized = transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "。")
            .replacingOccurrences(of: "；", with: "。")
            .replacingOccurrences(of: ";", with: "。")
        let parts = normalized.components(separatedBy: CharacterSet(charactersIn: "。！？!?."))
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 首句是标题候选，不重复放进正文；其余按目标长度合并成段落，句子保持完整。
    private static func buildParagraphs(from sentences: [String]) -> [String] {
        guard !sentences.isEmpty else { return [] }
        let body = Array(sentences.dropFirst())
        guard !body.isEmpty else { return [] }

        var paragraphs: [String] = []
        var current = ""
        for sentence in body {
            if !current.isEmpty && current.count + sentence.count > targetParagraphLength {
                paragraphs.append(current)
                current = sentence
            } else {
                current = current.isEmpty ? sentence : current + sentence
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs
    }

    /// 含强调词的句子 → 要点（保留原句；句子仍保留在段落里，正文完整不丢内容）。
    private static func extractKeyPoints(from sentences: [String]) -> [String] {
        guard !sentences.isEmpty else { return [] }
        return Array(sentences.dropFirst()).filter { sentence in
            keyPointKeywords.contains { sentence.contains($0) }
        }
    }

    private static func resolveTitle(_ title: String?, firstSentence: String?, date: Date) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let firstSentence, !firstSentence.isEmpty {
            let prefix = String(firstSentence.prefix(20))
            return prefix.count < firstSentence.count ? prefix + "…" : prefix
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "口述文档（\(formatter.string(from: date))）"
    }
}

/// AI JSON 输出容错解析：容忍 ``` 代码块包裹、前后多余文字、字段缺失/类型不标准。
/// 返回 nil = 解析不出标准 JSON（调用方走本地降级）。
enum DictationJSONParser {

    struct Draft {
        var title: String = ""
        var paragraphs: [String] = []
        var keyPoints: [String] = []
    }

    static func parse(_ raw: String) -> Draft? {
        guard let jsonString = extractJSONObject(from: raw),
              let data = jsonString.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        var draft = Draft()
        draft.title = stringValue(object["title"]) ?? ""
        draft.paragraphs = stringArray(object["paragraphs"])
        draft.keyPoints = stringArray(object["keyPoints"])
        return draft
    }

    /// 从 AI 输出里抠出第一个平衡的 JSON 对象（容忍 ```json 包裹 / 前后说明文字）。
    private static func extractJSONObject(from raw: String) -> String? {
        var text = raw
        if let lower = raw.range(of: "```json", options: .caseInsensitive) {
            text = String(raw[lower.upperBound...])
        } else if let fence = raw.range(of: "```") {
            text = String(raw[fence.upperBound...])
        }
        if let fence = text.range(of: "```") {
            text = String(text[..<fence.lowerBound])
        }

        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var endIndex: String.Index?
        for index in text[start...].indices {
            let char = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            switch char {
            case "\"":
                inString = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    endIndex = index
                }
            default:
                break
            }
            if endIndex != nil {
                break
            }
        }
        guard let endIndex else { return nil }
        return String(text[start...endIndex])
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    /// 字段容错：数组 → 逐项转字符串；单个字符串 → 按空行拆成多段；数字 → 转字符串。
    private static func stringArray(_ value: Any?) -> [String] {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return trimmed
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { stringValue($0) }
    }
}
