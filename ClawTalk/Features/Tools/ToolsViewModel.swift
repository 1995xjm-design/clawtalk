import Foundation
import UIKit

@Observable
@MainActor
final class ToolsViewModel {
    // Memory
    var memoryResults: [MemorySearchEntry] = []
    var memoryFileContent: MemoryGetResult?
    var memorySearchQuery = ""

    // Agents
    var agents: [AgentEntry] = []

    // Sessions
    var sessions: [SessionEntry] = []
    var sessionTitles: [String: String] = [:]
    var sessionStatus: String?
    var sessionHistory: SessionHistoryResult?

    // Browser
    var browserScreenshot: UIImage?
    var desktopScreenshot: UIImage?
    var browserStatusText: String?
    var browserTabsText: String?
    var browserToolAvailable = true
    var isInstallingBrowserTool = false

    // Models
    var availableModels: [ModelEntry] = []
    var isLoadingModels = false

    // Availability
    var toolAvailability: [ToolCategory: Bool] = [:]
    var availabilityChecked = false

    // Common
    var isLoading = false
    var errorMessage: String? {
        didSet { if let errorMessage { LogCollector.record(module: "工具", errorMessage) } }
    }

    private let client = OpenClawClient()
    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?

    /// I1：网关记忆工具名候选（实测 2026-08-13：`memory_search` 是 OpenClaw 官方记忆工具名，
    /// 当前网关 404 的根因是 openclaw.json 里 `plugins.slots.memory = "none"`（记忆模块未启用），
    /// 不是工具名错误。这里保留候选列表，未来网关启用记忆模块后即恢复；若网关改名，
    /// 直接追加候选名即可，无需改调用逻辑。
    private let memorySearchToolCandidates = ["memory_search", "memory-core"]
    private let memoryGetToolCandidates = ["memory_get", "memory-core"]

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
    }

    private var gatewayURL: String { settings.settings.gatewayURL }
    private var token: String {
        // 二维码配对后网关下发 device token（存 Keychain），优先取它；回退设置里的手填令牌。
        // 直接读 settings.gatewayToken 在配对场景是空的，会导致工具页全部 401/灰显。
        OpenClawClient.resolveHTTPToken(
            settingsToken: settings.gatewayToken,
            gatewayURL: settings.settings.gatewayURL
        )
    }

    enum ToolCategory: String, CaseIterable {
        case memory, agents, sessions, browser, models
    }

    func isAvailable(_ category: ToolCategory) -> Bool {
        if category == .models {
            return true  // HTTP /v1/models always available when gateway is configured
        }
        return toolAvailability[category] ?? true
    }

    // MARK: - Availability Check

    func checkAvailability() async {
        guard !availabilityChecked else { return }
        availabilityChecked = true

        let probes: [(ToolCategory, String, String?, [String: JSONValue]?)] = [
            (.memory, "memory_search", nil, ["query": .string("test"), "maxResults": .int(1)]),
            (.agents, "agents_list", nil, nil),
            (.sessions, "sessions_list", nil, ["limit": .int(1)]),
            (.browser, "browser", "status", nil),
        ]

        // 串行探测 + 小间隔：避免一次并发 4 个请求触发网关限流（历史日志大量 429）。
        for (category, tool, action, args) in probes {
            do {
                _ = try await client.invokeTool(
                    tool: tool,
                    action: action,
                    args: args,
                    gatewayURL: gatewayURL,
                    token: token
                )
                toolAvailability[category] = true
            } catch let error as OpenClawError {
                if case .toolNotFound = error {
                    toolAvailability[category] = false
                } else {
                    // Any other error means the tool exists but something else went wrong
                    toolAvailability[category] = true
                }
            } catch {
                toolAvailability[category] = true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Memory

    func searchMemory() async {
        let query = memorySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            let data = try await invokeMemoryTool(
                candidates: memorySearchToolCandidates,
                args: [
                    "query": .string(query),
                    "maxResults": .int(20),
                    "minScore": .double(0.15)
                ]
            )
            // Result is {content, details} — details has the structured data
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<MemorySearchResults>.self, from: data)
            memoryResults = wrapper.details?.results ?? []
        } catch let error as OpenClawError {
            if case .toolNotFound(let name) = error {
                errorMessage = "网关记忆工具未启用（\(name)）。请确认 openclaw.json 已启用记忆模块（plugins.slots.memory 不为 none）后重试。"
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func getMemoryFile(path: String, from: Int? = nil, lines: Int? = nil) async {
        isLoading = true
        errorMessage = nil

        do {
            var args: [String: JSONValue] = ["path": .string(path)]
            if let from { args["from"] = .int(from) }
            if let lines { args["lines"] = .int(lines) }

            let data = try await invokeMemoryTool(
                candidates: memoryGetToolCandidates,
                args: args
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<MemoryGetResult>.self, from: data)
            memoryFileContent = wrapper.details
        } catch let error as OpenClawError {
            if case .toolNotFound(let name) = error {
                errorMessage = "网关记忆工具未启用（\(name)）。请确认 openclaw.json 已启用记忆模块后重试。"
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// I1：依次尝试候选工具名，跳过「工具不存在」的候选；全部不存在时抛出最后一个 toolNotFound。
    private func invokeMemoryTool(
        candidates: [String],
        action: String? = nil,
        args: [String: JSONValue]
    ) async throws -> Data {
        var lastError: Error = OpenClawError.toolNotFound(candidates.first ?? "memory")
        for name in candidates {
            do {
                return try await client.invokeTool(
                    tool: name,
                    action: action,
                    args: args,
                    gatewayURL: gatewayURL,
                    token: token
                )
            } catch let error as OpenClawError {
                if case .toolNotFound = error {
                    lastError = error
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }
        throw lastError
    }

    // MARK: - Agents

    func listAgents() async {
        isLoading = true
        errorMessage = nil

        do {
            let data = try await client.invokeTool(
                tool: "agents_list",
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<AgentsListResult>.self, from: data)
            agents = wrapper.details?.agents ?? []
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Sessions

    func listSessions() async {
        isLoading = true
        errorMessage = nil

        do {
            let data = try await client.invokeTool(
                tool: "sessions_list",
                args: ["limit": .int(50)],
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<SessionsListResult>.self, from: data)
            let all = wrapper.details?.sessions ?? []
            // 过滤系统会话（evolution-check / subagent / cron / hook / preset）
            sessions = all.filter { !Self.isSystemSession($0.key) }
            // 为近期会话生成可读标题（取第一条用户消息），串行执行避免并发问题
            sessionTitles = [:]
            for session in sessions.prefix(20) {
                if let title = await fetchSessionTitle(session.key) {
                    sessionTitles[session.key] = title
                } else if let title = Self.friendlyTitle(for: session.key) {
                    sessionTitles[session.key] = title
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// 判断是否为系统会话（无对话内容，默认隐藏）
    static func isSystemSession(_ key: String) -> Bool {
        let markers = ["evolution-check", "subagent", "cron:", "hook:", "preset"]
        return markers.contains { key.contains($0) }
    }

    /// 从会话 key 生成友好中文标题；无法识别时返回 nil
    static func friendlyTitle(for key: String) -> String? {
        let prefix = "agent:main:"
        guard key.hasPrefix(prefix) else { return nil }
        let rest = String(key.dropFirst(prefix.count))
        switch rest {
        case "clawtalk-user:wechat-bind":
            return "微信绑定"
        case "clawtalk-user:diag":
            return "日志诊断"
        case "clawtalk-user:file-transfer":
            return "文件传输助手"
        case let r where r.hasPrefix("clawtalk-user:"):
            return "智能体会话"
        case let r where r.hasPrefix("openai-user:"):
            let hash = r.dropFirst("openai-user:".count)
            return "OpenAI 会话 \(hash.prefix(6))"
        default:
            return nil
        }
    }

    /// 取会话的第一条用户文本消息作为标题（最多 20 字）
    private func fetchSessionTitle(_ key: String) async -> String? {
        do {
            let data = try await client.invokeTool(
                tool: "sessions_history",
                args: ["sessionKey": .string(key), "limit": .int(100)],
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<SessionHistoryResult>.self, from: data)
            guard let history = wrapper.details else { return nil }
            // 按时间升序的 messages 中，取最早一条用户文本消息即可；若顺序不确定，先按 timestamp 排序
            let sortedMessages = history.messages.sorted {
                ($0.timestamp ?? 0) < ($1.timestamp ?? 0)
            }
            for message in sortedMessages where message.role == "user" {
                for content in message.content where content.type == "text" {
                    if let text = content.text {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed.count > 20 ? String(trimmed.prefix(20)) + "…" : trimmed
                        }
                    }
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func getSessionStatus(sessionKey: String? = nil) async {
        isLoading = true
        errorMessage = nil

        do {
            var args: [String: JSONValue]?
            if let sessionKey {
                args = ["sessionKey": .string(sessionKey)]
            }

            let data = try await client.invokeTool(
                tool: "session_status",
                args: args,
                gatewayURL: gatewayURL,
                token: token
            )
            // session_status returns text in content and details
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<SessionStatusResult.StatusDetails>.self, from: data)
            sessionStatus = wrapper.details?.statusText
                ?? wrapper.content?.first?.text
                ?? "No status available"
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func getSessionHistory(sessionKey: String, limit: Int = 20) async {
        isLoading = true
        errorMessage = nil

        do {
            let data = try await client.invokeTool(
                tool: "sessions_history",
                args: [
                    "sessionKey": .string(sessionKey),
                    "limit": .int(limit)
                ],
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<SessionHistoryResult>.self, from: data)
            sessionHistory = wrapper.details
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Browser

    func getBrowserStatus() async {
        isLoading = true
        errorMessage = nil

        do {
            let data = try await client.invokeTool(
                tool: "browser",
                action: "status",
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<BrowserDetails>.self, from: data)
            browserStatusText = wrapper.content?.first?.text ?? "No status"
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func takeBrowserScreenshot() async {
        isLoading = true
        errorMessage = nil

        do {
            let data = try await client.invokeTool(
                tool: "browser",
                action: "screenshot",
                args: ["type": .string("jpeg")],
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<BrowserDetails>.self, from: data)
            if let imageItem = wrapper.content?.first(where: { $0.type == "image" }),
               let base64 = imageItem.image?.data,
               let decoded = Data(base64Encoded: base64) {
                browserScreenshot = UIImage(data: decoded)
            } else if let textContent = wrapper.content?.first?.text,
                      let decoded = Data(base64Encoded: textContent) {
                browserScreenshot = UIImage(data: decoded)
            }
        } catch {
            errorMessage = Self.isRateLimit(error) ? "网关限流（429），请稍后重试" : error.localizedDescription
        }

        isLoading = false
    }

    func getBrowserTabs() async {
        isLoading = true
        errorMessage = nil

        do {
            let data = try await client.invokeTool(
                tool: "browser",
                action: "tabs",
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<BrowserDetails>.self, from: data)
            browserTabsText = wrapper.content?.first?.text ?? "No tabs"
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Browser Tool 检测 / 安装 / 桌面截图

    func checkBrowserTool() async {
        do {
            let data = try await client.invokeTool(
                tool: "browser",
                action: "status",
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<BrowserDetails>.self, from: data)
            browserToolAvailable = wrapper.content?.first?.text != nil || wrapper.details?.ok == true
        } catch {
            browserToolAvailable = false
        }
    }

    func installBrowserTool() async {
        guard !isInstallingBrowserTool else { return }
        isInstallingBrowserTool = true
        errorMessage = nil
        defer { isInstallingBrowserTool = false }
        let instruction = "请安装浏览器控制工具 chrome-devtools-mcp：1）npm install -g chrome-devtools-mcp；2）配置到 OpenClaw 的 MCP（找到 config/mcporter.json，在 mcpServers 添加 chrome-devtools-mcp，command 用 npx chrome-devtools-mcp）；3）让网关加载新的 MCP 配置；4）完成后回复「安装完成」；如果已经安装请直接回复「已安装」。"
        do {
            _ = try await client.chat(
                messages: [Message(role: .user, content: instruction)],
                gatewayURL: gatewayURL,
                token: token
            )
            await checkBrowserTool()
        } catch {
            errorMessage = Self.isRateLimit(error) ? "安装指令执行失败：网关限流（429），请稍后重试" : "安装指令执行失败：\(error.localizedDescription)"
        }
    }

    func takeDesktopScreenshot() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let instruction = "请用 PowerShell 截取整个桌面屏幕：1）Add-Type -AssemblyName System.Windows.Forms,System.Drawing；2）用 Graphics.CopyFromScreen 截取全屏；3）保存为 JPEG 并压缩到宽约 1200；4）转成 base64；5）回复我完整的 base64 字符串，不要省略、不要解释、不要加任何前缀。"
        do {
            let reply = try await client.chat(
                messages: [Message(role: .user, content: instruction)],
                gatewayURL: gatewayURL,
                token: token
            )
            if let b64 = Self.extractBase64(from: reply), let decoded = Data(base64Encoded: b64) {
                desktopScreenshot = UIImage(data: decoded)
            } else {
                errorMessage = "未从回复中解析到截图数据"
            }
        } catch {
            errorMessage = Self.isRateLimit(error) ? "截图指令执行失败：网关限流（429），请稍后重试" : "截图指令执行失败：\(error.localizedDescription)"
        }
    }

    static func extractBase64(from text: String) -> String? {
        let pattern = #"[A-Za-z0-9+/=]{1000,}"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    // MARK: - Models

    func loadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        errorMessage = nil

        defer { isLoadingModels = false }

        // Try HTTP first — works regardless of WebSocket state.
        do {
            availableModels = try await client.fetchModels(
                gatewayURL: gatewayURL,
                token: token
            )
            return
        } catch {
            // Fall back to WebSocket RPC
        }

        // WebSocket fallback
        guard let gateway = gatewayConnection,
              gateway.connectionState == .connected
        else {
            errorMessage = "无法加载模型"
            return
        }

        do {
            availableModels = try await gateway.modelsList()
        } catch {
            errorMessage = "加载模型失败：\(error.localizedDescription)"
        }
    }
}
