import Foundation
import Observation

/// 摘要结果：record 未落库 + 诚实来源信息（与 DictationOrganizationResult 同模式）。
struct SummaryResult {
    let record: SummaryRecord
    /// true = 本地规则降级（AI 未接入 / 调用失败 / 输出无法解析）
    let usedFallback: Bool
    /// 降级原因（展示给用户，诚实说明为什么没用 AI）
    let fallbackReason: String?
    /// AI 调用原始错误（仅记录日志用）
    let aiError: Error?
}

/// 长文摘要本地存储 + 摘要逻辑，两条路：
/// ① 网关可用时调 OpenClawClient.stream（与 DictationOrganizer 同独立发送链路），
///    让 agent 输出 JSON {summary, keyPoints}；
/// ② 网关不可用 / 调用失败 / AI 输出不是标准 JSON → 本地规则降级，
///    结果带 usedFallback = true，UI 诚实标注「本地摘要（未接 AI）」。
/// 超长（> 20000 字）时：AI 路径只送前 8000 字，record.truncationNotice 记录截断提示；
/// 原始全文仍完整保存在 originalText，不丢内容。
@Observable
@MainActor
final class SummarizerStore {
    private(set) var records: [SummaryRecord] = []

    private let storageKey = "clawtalk_summary_records_v1"

    /// 超长阈值：超过即提示截断（AI 路径只送前 8000 字）。
    static let maxCharacterCount = 20000
    /// AI 提示词送出的最大字符数（与 DictationOrganizer 同策略）。
    private static let aiPromptCharacterLimit = 8000

    // MARK: - App Group 分享契约（与 ClawTalkShareExtension/ShareConstants.swift 保持一致）

    private static let shareSuiteName = "group.7518554"
    private static let pendingMessageKey = "pending_share_message"

    /// 分享扩展写入的待发消息契约（主 App 侧 ClawTalkApp.swift 同款结构）。
    private struct PendingShareMessage: Codable {
        var channelId: String
        var channelName: String
        var text: String
        var attachments: [PendingShareAttachment]
        var createdAt: TimeInterval
    }

    private struct PendingShareAttachment: Codable {
        var fileName: String
        var containerPath: String
        var mimeType: String
    }

    init() {
        load()
    }

    // MARK: - 查询

    var totalCount: Int {
        records.count
    }

    /// 最近一条摘要的日期（卡片摘要用；无记录返回 nil，卡片显示诚实空状态）。
    var lastRecordDate: Date? {
        records.first?.createdAt
    }

    /// 最近若干条（列表展示，最新在前）。
    func recentRecords(limit: Int = 10) -> [SummaryRecord] {
        Array(records.prefix(limit))
    }

    func record(id: UUID) -> SummaryRecord? {
        records.first { $0.id == id }
    }

    // MARK: - 增删改查

    @discardableResult
    func add(_ record: SummaryRecord) -> SummaryRecord {
        records.insert(record, at: 0)
        persist()
        return record
    }

    func update(_ record: SummaryRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        persist()
    }

    func delete(id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    // MARK: - 持久化（UserDefaults JSON）

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SummaryRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - 分享接收（只读预填，不消费标记）

    /// 读取分享扩展写入的待发文本（pending_share_message）。
    /// 只读不消费：不动 pending_share_flag，避免影响 ClawTalkApp 启动/进前台时的
    /// 「分享内容 → 目标频道」发送轮询（那份待发消息仍会正常发到频道，摘要页只是借用文本预填）。
    func readSharedText() -> String? {
        guard let defaults = UserDefaults(suiteName: Self.shareSuiteName),
              let data = defaults.data(forKey: Self.pendingMessageKey),
              let pending = try? JSONDecoder().decode(PendingShareMessage.self, from: data)
        else { return nil }
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - 摘要

    func summarize(
        text: String,
        length: SummaryLength,
        source: SummarySource,
        settings: SettingsStore
    ) async -> SummaryResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncationNotice = Self.truncationNotice(for: trimmed)
        let fallback = SummaryLocalSummarizer.makeRecord(
            text: trimmed,
            length: length,
            source: source,
            truncationNotice: truncationNotice
        )

        guard !trimmed.isEmpty else {
            return SummaryResult(
                record: fallback,
                usedFallback: true,
                fallbackReason: "没有可摘要的内容",
                aiError: nil
            )
        }

        // ① 网关未配置 → 诚实降级（不假装调用 AI）
        guard settings.isConfigured else {
            return SummaryResult(
                record: fallback,
                usedFallback: true,
                fallbackReason: "未配置 OpenClaw 网关",
                aiError: nil
            )
        }

        do {
            let raw = try await requestAIReply(text: trimmed, length: length, settings: settings)
            if let draft = SummaryJSONParser.parse(raw) {
                let record = SummaryRecord(
                    originalText: trimmed,
                    summary: draft.summary.isEmpty ? fallback.summary : draft.summary,
                    keyPoints: draft.keyPoints.isEmpty ? fallback.keyPoints : draft.keyPoints,
                    source: source,
                    length: length,
                    usedFallback: false,
                    truncationNotice: truncationNotice
                )
                return SummaryResult(record: record, usedFallback: false, fallbackReason: nil, aiError: nil)
            }
            // AI 返回了内容但解析不出标准 JSON → 诚实降级，不硬编
            return SummaryResult(
                record: fallback,
                usedFallback: true,
                fallbackReason: "AI 返回内容无法解析成摘要",
                aiError: nil
            )
        } catch {
            // 网络失败 / 超时 / 空回复 → 诚实降级
            return SummaryResult(
                record: fallback,
                usedFallback: true,
                fallbackReason: "AI 摘要失败（\(Self.friendlyError(error))）",
                aiError: error
            )
        }
    }

    /// 超长截断提示：原文超过 20000 字时如实告知（AI 路径只送前 8000 字）。
    private static func truncationNotice(for text: String) -> String? {
        guard text.count > maxCharacterCount else { return nil }
        return "原文超过 \(maxCharacterCount) 字，已截断前 \(aiPromptCharacterLimit) 字送入 AI，摘要仅基于截断部分；原始全文已完整保存。"
    }

    // MARK: - AI 独立发送链路（与 DictationOrganizer 同模式）

    /// 默认模型：跟随默认频道 agent，兜底 "main"（与 DictationOrganizer 同策略）。
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

    /// OpenClawClient.stream 流式累积回复，90 秒超时兜底。
    private static func requestAIReply(
        text: String,
        length: SummaryLength,
        settings: SettingsStore
    ) async throws -> String {
        let token = OpenClawClient.resolveHTTPToken(
            settingsToken: settings.gatewayToken,
            gatewayURL: settings.settings.gatewayURL
        )

        let prompt = Self.aiPrompt(text: text, length: length)
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
                    throw SummarizeError.timeout
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
            throw SummarizeError.emptyReply
        }
        return trimmed
    }

    /// AI 提示词：要求只输出 JSON {summary, keyPoints}，按长度档位约束，禁止编造。
    /// 超长原文截断到 8000 字再送 AI（原始全文仍完整保存在 record.originalText）。
    private static func aiPrompt(text: String, length: SummaryLength) -> String {
        let capped = text.count > aiPromptCharacterLimit
            ? String(text.prefix(aiPromptCharacterLimit)) + "…（后续内容省略）"
            : text
        return """
        你是长文摘要助手。请把下面的长文本压缩成要点摘要，只输出一个 JSON 对象，不要输出任何其他文字、解释或 Markdown 代码块标记。

        输出格式（严格按此结构）：
        {
          "summary": "摘要正文（一段话）",
          "keyPoints": ["要点一", "要点二"]
        }

        长度要求：\(length.aiDirective)

        规则：
        - 只输出 JSON，禁止在 JSON 前后添加说明文字。
        - summary 是连贯的一段摘要，忠实于原文，不要编造原文没有的信息。
        - keyPoints 只提取原文里明确强调的重点；没有明确重点就用空数组，不要编造。
        - 如果原文本身很短，summary 直接概括原文即可。

        长文本内容：
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

/// 摘要专属错误。
enum SummarizeError: LocalizedError {
    case timeout
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .timeout: return "等待 AI 回复超时"
        case .emptyReply: return "AI 没有返回内容"
        }
    }
}

/// 本地规则降级摘要（诚实兜底，不造假）：
/// 按句号/换行切分句子；首句作为摘要开头，按长度档位续补句子并截断；
/// 含「重点/关键是」等强调词的句子提取为要点（保留原句，不改写）。
enum SummaryLocalSummarizer {

    private static let keyPointKeywords = ["重点", "关键是", "记住", "注意", "切记", "最重要的是", "特别提醒", "别忘了"]

    static func makeRecord(
        text: String,
        length: SummaryLength,
        source: SummarySource,
        truncationNotice: String?
    ) -> SummaryRecord {
        let sentences = splitSentences(text)
        let summary = buildSummary(from: sentences, targetLength: length.localSummaryTarget)
        let keyPoints = extractKeyPoints(from: sentences, limit: length.localKeyPointLimit)

        return SummaryRecord(
            originalText: text,
            summary: summary,
            keyPoints: keyPoints,
            source: source,
            length: length,
            usedFallback: true,
            truncationNotice: truncationNotice
        )
    }

    /// 按中英文句末标点切分（句号/问号/感叹号/分号/换行），与口述整理同规则。
    private static func splitSentences(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "。")
            .replacingOccurrences(of: "；", with: "。")
            .replacingOccurrences(of: ";", with: "。")
        let parts = normalized.components(separatedBy: CharacterSet(charactersIn: "。！？!?."))
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 摘要 = 首句开头，按目标长度续补句子，最后截断到目标长度（尽量保持句子完整）。
    private static func buildSummary(from sentences: [String], targetLength: Int) -> String {
        guard !sentences.isEmpty else { return "" }
        var result = sentences[0]
        guard result.count < targetLength else {
            return truncated(result, to: targetLength)
        }
        for sentence in sentences.dropFirst() {
            if result.count + sentence.count > targetLength {
                break
            }
            result += sentence
        }
        return truncated(result, to: targetLength)
    }

    /// 含强调词的句子 → 要点（保留原句；句子仍完整保留在摘要/原文里，不丢内容）。
    private static func extractKeyPoints(from sentences: [String], limit: Int) -> [String] {
        guard !sentences.isEmpty, limit > 0 else { return [] }
        let matched = sentences.dropFirst().filter { sentence in
            keyPointKeywords.contains { sentence.contains($0) }
        }
        return Array(matched.prefix(limit))
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

/// AI JSON 输出容错解析（字段：summary/keyPoints），容忍 ``` 代码块包裹、前后多余文字。
/// 返回 nil = 解析不出标准 JSON（调用方走本地降级）。
enum SummaryJSONParser {

    struct Draft {
        var summary: String = ""
        var keyPoints: [String] = []
    }

    static func parse(_ raw: String) -> Draft? {
        guard let jsonString = extractJSONObject(from: raw),
              let data = jsonString.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        var draft = Draft()
        draft.summary = stringValue(object["summary"]) ?? ""
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

    /// 字段容错：数组 → 逐项转字符串；单个字符串 → 按空行拆成多条；数字 → 转字符串。
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
