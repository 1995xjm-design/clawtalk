import Foundation

/// 整理结果：note 为整理好的纪要（未落库）+ 诚实来源信息。
struct MeetingOrganizationResult {
    let note: MeetingNote
    /// true = 本地规则降级（AI 未接入 / 调用失败 / 输出无法解析）
    let usedFallback: Bool
    /// 降级原因（展示给用户，诚实说明为什么没用 AI）
    let fallbackReason: String?
    /// AI 调用原始错误（仅记录日志用）
    let aiError: Error?
}

/// 会议纪要整理逻辑，两条路：
/// ① 网关可用时调 OpenClawClient.stream（与 ChatViewModel.send /
///    VoiceAssistantViewModel.requestAgentReplyViaGateway 同独立发送链路），
///    让 agent 把转写整理成 JSON 格式纪要；
/// ② 网关不可用 / 调用失败 / AI 输出不是标准 JSON → 本地规则降级，
///    结果带 `organizedByAI = false`，UI 诚实标注「本地整理（未接 AI）」。
struct MeetingOrganizer {

    /// 默认模型：跟随默认频道 agent，兜底 "main"（与 VoiceAssistantViewModel 同策略）。
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
        participants: [String],
        date: Date,
        audioFileName: String? = nil,
        settings: SettingsStore
    ) async -> MeetingOrganizationResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = MeetingLocalOrganizer.makeNote(
            transcript: trimmed,
            title: title,
            participants: participants,
            date: date
        )
        var fallbackNote = fallback
        fallbackNote.audioFileName = audioFileName

        guard !trimmed.isEmpty else {
            return MeetingOrganizationResult(
                note: fallbackNote,
                usedFallback: true,
                fallbackReason: "没有可整理的转写内容",
                aiError: nil
            )
        }

        // ① 网关不可用 → 诚实降级（不假装调用 AI）
        guard settings.isConfigured else {
            return MeetingOrganizationResult(
                note: fallbackNote,
                usedFallback: true,
                fallbackReason: "未配置 OpenClaw 网关",
                aiError: nil
            )
        }

        do {
            let raw = try await requestAIReply(transcript: trimmed, settings: settings)
            if let draft = MeetingJSONParser.parse(raw) {
                let note = MeetingNote(
                    date: date,
                    title: draft.title.isEmpty ? fallback.title : draft.title,
                    participants: draft.participants.isEmpty ? participants : draft.participants,
                    topics: draft.topics,
                    decisions: draft.decisions,
                    actionItems: draft.actionItems,
                    summary: draft.summary.isEmpty ? fallback.summary : draft.summary,
                    rawTranscript: trimmed,
                    audioFileName: audioFileName,
                    organizedByAI: true
                )
                return MeetingOrganizationResult(note: note, usedFallback: false, fallbackReason: nil, aiError: nil)
            }
            // AI 返回了内容但解析不出标准 JSON → 诚实降级，不硬编
            return MeetingOrganizationResult(
                note: fallbackNote,
                usedFallback: true,
                fallbackReason: "AI 返回内容无法解析成纪要",
                aiError: nil
            )
        } catch {
            // 网络失败 / 超时 / 空回复 → 诚实降级
            return MeetingOrganizationResult(
                note: fallbackNote,
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
                    throw MeetingOrganizeError.timeout
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
            throw MeetingOrganizeError.emptyReply
        }
        return trimmed
    }

    /// AI 提示词：要求只输出 JSON，字段与 MeetingNote 对齐，禁止编造。
    /// 转写超长时截断到 8000 字再送 AI（原始全文仍完整保存在 rawTranscript，不丢内容）。
    private static func aiPrompt(transcript: String) -> String {
        let capped = transcript.count > 8000 ? String(transcript.prefix(8000)) + "…（后续内容省略）" : transcript
        return """
        你是会议纪要整理助手。请把下面的会议转写整理成结构化纪要，只输出一个 JSON 对象，不要输出任何其他文字、解释或 Markdown 代码块标记。

        输出格式（严格按此结构）：
        {
          "title": "会议标题（一句话概括，15 字以内）",
          "participants": ["参与者姓名"],
          "topics": ["讨论议题（每条一个）"],
          "decisions": ["形成的决定（每条一个）"],
          "actionItems": [{"text": "待办事项", "assignee": "负责人（不确定就省略）", "dueDate": "YYYY-MM-DD（不确定就省略）"}],
          "summary": "整体摘要（两到三句话）"
        }

        规则：
        - 只输出 JSON，禁止在 JSON 前后添加说明文字。
        - 没有的字段用空数组，不要编造内容。
        - dueDate 只写具体日期（YYYY-MM-DD），没有就省略该字段。
        - 待办里出现明确负责人（如「由张三负责」）才填 assignee，否则省略。

        会议转写内容：
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

/// 会议整理专属错误。
enum MeetingOrganizeError: LocalizedError {
    case timeout
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .timeout: return "等待 AI 回复超时"
        case .emptyReply: return "AI 没有返回内容"
        }
    }
}

/// 本地规则降级整理（诚实兜底，不造假）。
/// 按句号分段；含「决定/同意/确认/拍板」→ 决定；含「待办/需要做/我来/跟进」→ 待办；
/// 其他 → 议题摘要。标题/负责人/截止时间识别不到就不编造。
enum MeetingLocalOrganizer {

    static func makeNote(transcript: String, title: String?, participants: [String], date: Date) -> MeetingNote {
        let segments = splitSentences(transcript)
        var topics: [String] = []
        var decisions: [String] = []
        var actionItems: [ActionItem] = []

        for segment in segments {
            let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if containsAny(text, in: decisionKeywords) {
                decisions.append(text)
            } else if containsAny(text, in: actionKeywords) {
                actionItems.append(ActionItem(text: text, assignee: extractAssignee(from: text)))
            } else {
                topics.append(text)
            }
        }

        let resolvedTitle = resolveTitle(title, firstSegment: segments.first, date: date)
        let summary = makeSummary(topics: topics, decisions: decisions, actionItems: actionItems, transcript: transcript)

        return MeetingNote(
            date: date,
            title: resolvedTitle,
            participants: participants,
            topics: topics,
            decisions: decisions,
            actionItems: actionItems,
            summary: summary,
            rawTranscript: transcript,
            organizedByAI: false
        )
    }

    private static let decisionKeywords = ["决定", "同意", "确认", "拍板", "定了", "就这么办", "通过"]
    private static let actionKeywords = ["待办", "需要做", "要做", "我来", "记得", "别忘了", "跟进", "负责", "安排"]

    /// 按中英文句末标点切分（句号/问号/感叹号/分号/换行）。
    private static func splitSentences(_ transcript: String) -> [String] {
        let normalized = transcript
            .replacingOccurrences(of: "\n", with: "。")
            .replacingOccurrences(of: "；", with: "。")
            .replacingOccurrences(of: ";", with: "。")
        let parts = normalized.components(separatedBy: CharacterSet(charactersIn: "。！？!?."))
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func containsAny(_ text: String, in keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    /// 「由张三负责」→ 张三；「我来」→ 我（自己）；识别不到返回 nil，不编造。
    private static func extractAssignee(from text: String) -> String? {
        let patterns = ["由(.+?)负责", "由(.+?)处理", "由(.+?)来做", "交给(.+?)"]
        for pattern in patterns {
            if let match = firstMatch(pattern, in: text),
               match.groups.count > 1 {
                let name = match.groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    return name
                }
            }
        }
        if text.contains("我来") {
            return "我"
        }
        return nil
    }

    private static func resolveTitle(_ title: String?, firstSegment: String?, date: Date) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let firstSegment, !firstSegment.isEmpty {
            let prefix = String(firstSegment.prefix(20))
            return prefix.count < firstSegment.count ? prefix + "…" : prefix
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "会议纪要（\(formatter.string(from: date))）"
    }

    /// 摘要：议题/决定/待办数量 + 首条议题，如实反映整理结果。
    private static func makeSummary(topics: [String], decisions: [String], actionItems: [ActionItem], transcript: String) -> String {
        let countText = "本次整理出 \(topics.count) 个议题、\(decisions.count) 项决定、\(actionItems.count) 项待办。"
        if let firstTopic = topics.first {
            return countText + " 主要讨论了「\(firstTopic)」"
        }
        let prefix = String(transcript.prefix(40))
        return countText + (prefix.isEmpty ? "" : " 转写内容：\(prefix)…")
    }

    /// 正则首个匹配：整体 + 捕获组；无匹配返回 nil。
    private static func firstMatch(_ pattern: String, in text: String) -> (whole: String, groups: [String])? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            let range = match.range(at: index)
            groups.append(range.location == NSNotFound ? "" : nsText.substring(with: range))
        }
        guard let whole = groups.first else { return nil }
        return (whole, groups)
    }
}

/// AI JSON 输出容错解析：容忍 ``` 代码块包裹、前后多余文字、字段缺失/类型不标准。
/// 返回 nil = 解析不出标准 JSON（调用方走本地降级）。
enum MeetingJSONParser {

    struct Draft {
        var title: String = ""
        var participants: [String] = []
        var topics: [String] = []
        var decisions: [String] = []
        var actionItems: [ActionItem] = []
        var summary: String = ""
    }

    static func parse(_ raw: String) -> Draft? {
        guard let jsonString = extractJSONObject(from: raw),
              let data = jsonString.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        var draft = Draft()
        draft.title = stringValue(object["title"]) ?? ""
        draft.summary = stringValue(object["summary"]) ?? ""
        draft.participants = stringArray(object["participants"])
        draft.topics = stringArray(object["topics"])
        draft.decisions = stringArray(object["decisions"])
        draft.actionItems = parseActionItems(object["actionItems"])
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

    private static func stringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { stringValue($0) }
    }

    /// actionItems 容错：元素可能是字典（标准格式）或字符串（宽松格式）。
    private static func parseActionItems(_ value: Any?) -> [ActionItem] {
        guard let array = value as? [Any] else { return [] }
        var items: [ActionItem] = []
        for element in array {
            if let dict = element as? [String: Any] {
                guard let text = stringValue(dict["text"]), !text.isEmpty else { continue }
                let assignee = stringValue(dict["assignee"])
                let dueDate = parseDueDate(stringValue(dict["dueDate"]))
                items.append(ActionItem(text: text, assignee: assignee, dueDate: dueDate))
            } else if let text = stringValue(element), !text.isEmpty {
                items.append(ActionItem(text: text))
            }
        }
        return items
    }

    /// 日期字符串容错：yyyy-MM-dd 或 yyyy/MM/dd，解析不了返回 nil（不硬编）。
    private static func parseDueDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.date(from: raw)
    }
}