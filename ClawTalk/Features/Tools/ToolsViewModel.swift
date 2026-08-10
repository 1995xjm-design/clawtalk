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

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
    }

    private var gatewayURL: String { settings.settings.gatewayURL }
    private var token: String { settings.gatewayToken }

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

        await withTaskGroup(of: (ToolCategory, Bool).self) { group in
            for (category, tool, action, args) in probes {
                group.addTask { [client, gatewayURL, token] in
                    do {
                        _ = try await client.invokeTool(
                            tool: tool,
                            action: action,
                            args: args,
                            gatewayURL: gatewayURL,
                            token: token
                        )
                        return (category, true)
                    } catch let error as OpenClawError {
                        if case .toolNotFound = error {
                            return (category, false)
                        }
                        // Any other error means the tool exists but something else went wrong
                        return (category, true)
                    } catch {
                        return (category, true)
                    }
                }
            }

            for await (category, available) in group {
                toolAvailability[category] = available
            }
        }
    }

    // MARK: - Memory

    func searchMemory() async {
        let query = memorySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            let data = try await client.invokeTool(
                tool: "memory_search",
                args: [
                    "query": .string(query),
                    "maxResults": .int(20),
                    "minScore": .double(0.15)
                ],
                gatewayURL: gatewayURL,
                token: token
            )
            // Result is {content, details} — details has the structured data
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<MemorySearchResults>.self, from: data)
            memoryResults = wrapper.details?.results ?? []
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

            let data = try await client.invokeTool(
                tool: "memory_get",
                args: args,
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<MemoryGetResult>.self, from: data)
            memoryFileContent = wrapper.details
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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

    /// 取会话的第一条用户文本消息作为标题（最多 20 字）
    private func fetchSessionTitle(_ key: String) async -> String? {
        do {
            let data = try await client.invokeTool(
                tool: "sessions_history",
                args: ["sessionKey": .string(key), "limit": .int(20)],
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<SessionHistoryResult>.self, from: data)
            guard let history = wrapper.details else { return nil }
            for message in history.messages where message.role == "user" {
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
            errorMessage = error.localizedDescription
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
            errorMessage = "安装指令执行失败：\(error.localizedDescription)"
        }
    }

    func takeDesktopScreenshot() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let instruction = "请用 PowerShell 截取整个桌面屏幕：1）Add-Type -AssemblyName System.Windows.Forms,System.Drawing；2）用 Graphics.CopyFromScreen 截取全屏；3）保存为 JPEG 并压缩到宽约 1200；4）转成 base64；5）回复我完整的 base64 字符串，不要���略、不要解释、不要加任何前缀。"
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
            errorMessage = "截图指令执行失败：\(error.localizedDescription)"
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
