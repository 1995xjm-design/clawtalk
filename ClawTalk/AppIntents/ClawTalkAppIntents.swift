import AppIntents
import Foundation

/// 快捷指令 App Intents：在主 App target 内即可使用，无需 App Intents 扩展，也无需改 project.yml。
/// 系统会自动发现 ClawTalkShortcuts（AppShortcutsProvider），无需额外配置。

enum ClawTalkIntentError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置网关，请先在 ClawTalk 设置里填写网关地址与令牌。"
        }
    }
}

/// 向 ClawTalk 发送消息：调用网关 chat 让 OpenClaw 智能体回复并返回回复内容。
@MainActor
struct ClawTalkSendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "向 ClawTalk 发送消息"
    static let description = IntentDescription("把文本消息发给 ClawTalk 网关上的 OpenClaw 智能体，并返回回复。")
    static let parameterSummary = Summary("发送「\(\.$text)」给 ClawTalk")

    @Parameter(title: "消息内容")
    var text: String

    @Parameter(title: "目标频道", default: "默认频道")
    var channelName: String

    func perform() async throws -> some IntentResult {
        let settings = SettingsStore()
        guard settings.isConfigured else { throw ClawTalkIntentError.notConfigured }

        let baseURL = settings.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let channel: Channel
        if channelName != "默认频道",
           let matched = ChannelStore.shared.channels.first(where: { $0.name == channelName }) {
            channel = matched
        } else {
            channel = ChannelStore.shared.channels.first ?? .default
        }

        let output = try await OpenClawClient().chat(
            messages: [Message(role: .user, content: text)],
            gatewayURL: baseURL,
            token: settings.gatewayToken,
            sessionKey: channel.serverSessionKey
        )
        return .result(value: output)
    }
}

/// 查看 ClawTalk 状态：配置情况 + WebSocket 开关 + 网关可达性（真实 HTTP 探测）。
@MainActor
struct ClawTalkStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "查看 ClawTalk 状态"
    static let description = IntentDescription("查看 ClawTalk 网关是否已配置、WebSocket 是否开启、网关是否可达。")

    func perform() async throws -> some IntentResult {
        let settings = SettingsStore()
        var lines: [String] = []
        if settings.isConfigured {
            lines.append("网关：\(settings.settings.gatewayURL)")
            lines.append("WebSocket：\(settings.settings.useWebSocket ? "已开启" : "未开启")")
            let reachable = await Self.probeGatewayReachability(url: settings.settings.gatewayURL, token: settings.gatewayToken)
            lines.append("网关可达：\(reachable ? "是" : "否（连接失败或超时）")")
        } else {
            lines.append("ClawTalk 网关未配置。")
        }
        return .result(value: lines.joined(separator: "\n"))
    }

    /// 真实可达性探测：POST /v1/chat/completions（空消息体），能拿到 HTTP 响应即视为可达。
    private static func probeGatewayReachability(url: String, token: String) async -> Bool {
        let baseURL = url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !baseURL.isEmpty, let target = URL(string: "\(baseURL)/v1/chat/completions") else { return false }

        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{\"model\":\"openclaw:main\",\"messages\":[],\"stream\":false}".utf8)
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}

/// 快捷指令入口（系统设置 > 快捷指令 中可搜索添加）。
struct ClawTalkShortcuts: AppShortcutsProvider {
    @MainActor static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ClawTalkSendMessageIntent(),
            phrases: ["用 \(.applicationName) 发送消息", "让 \(.applicationName) 发消息"],
            shortTitle: "发送消息",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: ClawTalkStatusIntent(),
            phrases: ["\(.applicationName) 当前状态"],
            shortTitle: "查看状态",
            systemImageName: "gauge"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .red
    }
}