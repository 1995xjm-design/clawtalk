import Foundation
import Observation

/// 知识库问答错误（诚实上报，不吞错）。
enum KBStoreError: LocalizedError {
    case emptyQuestion
    case notConfigured
    case emptyAgentReply

    var errorDescription: String? {
        switch self {
        case .emptyQuestion: return "问题不能为空。"
        case .notConfigured: return "请先在设置中配置 OpenClaw 网关。"
        case .emptyAgentReply: return "智能体没有返回有效回答。"
        }
    }
}

/// 知识库问答存储与查询：
/// 1. 本地持久化问答历史（UserDefaults JSON，最多 50 条）；
/// 2. ask() 先走网关 memory_search 检索记忆库：
///    - 有结果 → 组装答案（片段拼接 + 来源标注）；配置了 agent 时可选调
///      OpenClawClient.stream 让 agent 基于记忆回答，失败降级纯检索并如实标注；
///    - 无结果 → 如实提示「记忆库中没有找到相关内容」，不编造；
///    - 网关失败 → 如实提示错误，不编造。
/// 参考 MemorySearchTabViewModel.search（memory_search）与
/// VoiceAssistantViewModel.requestAgentReplyViaGateway（stream）。
@Observable
@MainActor
final class KBStore {
    /// 问答历史（新问答追加到末尾，展示时倒序）。
    private(set) var questions: [KBQuestion] = []
    /// 正在检索/回答中。
    private(set) var isAsking = false
    /// 最近一次错误（横条提示；同时也会作为 .error 记录写入历史）。
    var lastError: String?

    private let defaults = UserDefaults.standard
    private let historyKey = "kb_qa_history_v1"
    private let maxHistory = 50

    private let client = OpenClawClient()
    private let settings: SettingsStore
    /// agent 增强开关：非 nil 时先探测网关 agents_list，探测到则优先走
    /// OpenClawClient.stream（model "openclaw:<agentId>"）让 agent 基于记忆回答。
    private let agentId: String?
    /// agents_list 探测结果缓存（nil = 未探测）。
    private var agentAvailable: Bool?

    init(settings: SettingsStore, agentId: String? = nil) {
        self.settings = settings
        self.agentId = agentId
        load()
    }

    // MARK: - 对外查询

    /// 提问：检索记忆库 → 组装/agent 回答 → 写入历史。
    func ask(_ question: String) async -> KBAnswer {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return KBAnswer(
                text: KBStoreError.emptyQuestion.localizedDescription,
                sources: [],
                kind: .error
            )
        }
        guard settings.isConfigured else {
            lastError = KBStoreError.notConfigured.localizedDescription
            let answer = KBAnswer(
                text: KBStoreError.notConfigured.localizedDescription,
                sources: [],
                kind: .error
            )
            record(question: trimmed, answer: answer)
            return answer
        }

        isAsking = true
        lastError = nil
        defer { isAsking = false }

        do {
            let entries = try await searchMemory(trimmed)

            // 无结果：诚实提示，不编造，不调 agent。
            guard !entries.isEmpty else {
                let answer = KBAnswer(
                    text: "记忆库中没有找到相关内容。可以换个问法，或先到「我的记忆」沉淀相关资料后再试。",
                    sources: [],
                    kind: .noResult
                )
                record(question: trimmed, answer: answer)
                return answer
            }

            let sources = Self.distinctPaths(entries)

            // agent 增强（可选）：探测到网关配置了 agent 时，让 agent 基于记忆回答；
            // 失败降级纯检索并如实标注。
            if await agentEnhancementAvailable() {
                do {
                    let text = try await askAgent(question: trimmed, entries: entries)
                    let answer = KBAnswer(text: text, sources: sources, kind: .agent)
                    record(question: trimmed, answer: answer)
                    return answer
                } catch {
                    LogCollector.record(
                        module: "知识库问答",
                        "智能体回答失败，降级为记忆库片段：\(AppErrorText.localized(error.localizedDescription))"
                    )
                    let answer = KBAnswer(
                        text: Self.assembledAnswer(entries: entries, degradeNote: "智能体回答失败，以下为记忆库片段："),
                        sources: sources,
                        kind: .memory
                    )
                    record(question: trimmed, answer: answer)
                    return answer
                }
            }

            // 纯检索路径：片段拼接 + 来源标注。
            let answer = KBAnswer(
                text: Self.assembledAnswer(entries: entries, degradeNote: nil),
                sources: sources,
                kind: .memory
            )
            record(question: trimmed, answer: answer)
            return answer
        } catch {
            let message = AppErrorText.localized(error.localizedDescription)
            lastError = message
            LogCollector.record(module: "知识库问答", "记忆库检索失败：\(message)")
            let answer = KBAnswer(text: "记忆库检索失败：\(message)", sources: [], kind: .error)
            record(question: trimmed, answer: answer)
            return answer
        }
    }

    /// 清空问答历史（持久化）。
    func clearHistory() {
        questions.removeAll()
        save()
    }

    // MARK: - 卡片统计

    /// 今日问答数（卡片角标）。
    var todayCount: Int {
        questions.filter { Calendar.current.isDateInToday($0.askedAt) }.count
    }

    var totalCount: Int {
        questions.count
    }

    // MARK: - 记忆库检索（与 MemorySearchTabViewModel.search 同款调用）

    private func searchMemory(_ query: String) async throws -> [MemorySearchEntry] {
        let data = try await client.invokeTool(
            tool: "memory_search",
            args: [
                "query": .string(query),
                "maxResults": .int(8),
                "minScore": .double(0.15)
            ],
            gatewayURL: gatewayURL,
            token: token
        )
        let wrapper = try JSONDecoder().decode(ToolResultWrapper<MemorySearchResults>.self, from: data)
        return wrapper.details?.results ?? []
    }

    // MARK: - agent 增强（可选）

    /// 探测网关是否配置了 agent（agents_list，与 ToolsViewModel.listAgents 同款）。
    /// 探测失败（工具不存在/网络问题）时乐观启用：让 stream 尝试一次，
    /// 失败会在 ask() 中降级纯检索并如实标注，不阻塞纯检索链路。
    private func agentEnhancementAvailable() async -> Bool {
        if let agentAvailable { return agentAvailable }
        guard let agentId, !agentId.isEmpty else {
            agentAvailable = false
            return false
        }
        var available = true
        do {
            let data = try await client.invokeTool(tool: "agents_list", gatewayURL: gatewayURL, token: token)
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<AgentsListResult>.self, from: data)
            let agents = wrapper.details?.agents ?? []
            available = agents.contains { $0.agentId == agentId }
        } catch {
            available = true
        }
        agentAvailable = available
        return available
    }

    /// 让 agent 基于记忆库资料回答（OpenClawClient.stream，参考 VoiceAssistantViewModel.requestAgentReplyViaGateway）。
    private func askAgent(question: String, entries: [MemorySearchEntry]) async throws -> String {
        let context = entries.enumerated().map { index, entry in
            "[资料 \(index + 1)] 来源：\(entry.path)\n\(entry.snippet)"
        }.joined(separator: "\n\n")

        let userContent = """
        请基于以下「记忆库资料」回答我的问题。
        要求：
        1. 只使用资料中的内容回答；资料不足以回答时如实说明「记忆库中的资料不足以回答」，不要编造。
        2. 用简体中文简明回答。
        3. 回答末尾列出引用的来源路径。

        【记忆库资料】
        \(context)

        【问题】
        \(question)
        """

        let stream = client.stream(
            messages: [Message(role: .user, content: userContent)],
            gatewayURL: gatewayURL,
            token: token,
            model: "openclaw:\(agentId ?? "main")",
            apiMode: settings.settings.agentAPIMode,
            sessionKey: nil,
            messageChannel: "kb"
        )

        var reply = ""
        for try await event in stream {
            if case .textDelta(let delta) = event {
                reply += delta
            }
        }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KBStoreError.emptyAgentReply }
        return trimmed
    }

    // MARK: - 组装

    /// 纯检索答案：片段编号 + 来源路径 + 片段（来源标注内嵌在答案中，UI 另列 sources 列表）。
    private static func assembledAnswer(entries: [MemorySearchEntry], degradeNote: String?) -> String {
        var lines: [String] = []
        if let degradeNote, !degradeNote.isEmpty {
            lines.append(degradeNote)
        }
        for (index, entry) in entries.enumerated() {
            let snippet = entry.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(index + 1). \(entry.path)")
            if !snippet.isEmpty {
                lines.append("    \(snippet)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 去重后的来源路径列表（保持命中顺序）。
    private static func distinctPaths(_ entries: [MemorySearchEntry]) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for entry in entries {
            let path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            paths.append(path)
        }
        return paths
    }

    // MARK: - 历史持久化

    private func record(question: String, answer: KBAnswer) {
        let entry = KBQuestion(
            question: question,
            answer: answer.text,
            sources: answer.sources,
            kind: answer.kind
        )
        questions.append(entry)
        if questions.count > maxHistory {
            questions.removeFirst(questions.count - maxHistory)
        }
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([KBQuestion].self, from: data) else { return }
        questions = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(questions) {
            defaults.set(data, forKey: historyKey)
        }
    }

    // MARK: - 依赖

    private var gatewayURL: String { settings.settings.gatewayURL }
    private var token: String {
        OpenClawClient.resolveHTTPToken(settingsToken: settings.gatewayToken, gatewayURL: gatewayURL)
    }
}
