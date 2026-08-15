import Foundation

/// 全局统一 AI 接入层（C10）：
/// - 按设置自动选择「直连 DeepSeek / 网关通道」；
/// - 统一注入 L1/L2/L3 本地分层记忆 + 电脑同步快照（电脑关机后仍用本地记忆与最后快照，思维一致）；
/// - 对外只暴露一个流式入口，业务方不再各自拼通道。
final class AIService {
    static let shared = AIService()
    private init() {}

    enum AIServiceError: LocalizedError {
        case notConfigured
        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "尚未连接网关：请先配对或填写网关地址与令牌"
            }
        }
    }

    /// 统一流式生成：prompt 为业务提示，purpose 用于记忆注入说明（如「模仿用户口吻改写一句话」）。
    func stream(
        prompt: String,
        purpose: String,
        memoryStore: MemoryProfileStore,
        settingsStore: SettingsStore,
        sessionKey: String? = nil,
        messageChannel: String = "ai-service"
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let system = MemoryPromptBuilder.build(
                        profiles: memoryStore.profiles,
                        computerSummary: MemorySyncService.shared.computerSummary,
                        dialogueSnippet: MemorySyncService.shared.recentDialogueSnippet,
                        recentDialogue: [],
                        purpose: purpose
                    )
                    if settingsStore.settings.voiceAgentChannel == .directDeepSeek {
                        for try await delta in DeepSeekDirectClient.shared.stream(
                            messages: [DeepSeekChatMessage(role: "user", content: prompt)],
                            system: system
                        ) {
                            continuation.yield(delta)
                        }
                    } else {
                        guard settingsStore.isConfigured else {
                            throw AIServiceError.notConfigured
                        }
                        let stream = OpenClawClient().stream(
                            messages: [Message(role: .user, content: prompt)],
                            gatewayURL: settingsStore.settings.gatewayURL,
                            token: OpenClawClient.resolveHTTPToken(
                                settingsToken: settingsStore.gatewayToken,
                                gatewayURL: settingsStore.settings.gatewayURL
                            ),
                            model: "openclaw:main",
                            apiMode: settingsStore.settings.agentAPIMode,
                            sessionKey: sessionKey,
                            messageChannel: messageChannel
                        )
                        for try await event in stream {
                            if case .textDelta(let delta) = event {
                                continuation.yield(delta)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
