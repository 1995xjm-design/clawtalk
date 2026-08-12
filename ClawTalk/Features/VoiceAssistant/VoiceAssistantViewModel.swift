import Foundation
import SwiftUI
import UIKit

/// 语音助手四种会话状态（对应卡片四种动画）。
enum VoiceAssistantState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
}

/// 语音助手专用错误。
enum VoiceAssistantError: LocalizedError {
    case notConfigured(String)
    case busy
    case emptyReply
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): return message
        case .busy: return "聊天页正在使用麦克风或朗读，请稍后再试。"
        case .emptyReply: return "智能体没有返回有效回复。"
        case .timeout: return "等待回复超时，请检查网络后重试。"
        }
    }
}

/// 随身语音助手「连续对讲」会话管理器。
///
/// 状态机（一轮连续对讲）：
///
///   idle ──startConversation──▶ listening
///   listening ──VAD 检测到说话（停顿自动结束）──▶ thinking
///   thinking ──转写 + 智能体回复完成──▶ speaking
///   speaking ──朗读完成──▶ listening（下一轮，轮数 +1）
///   speaking ──用户开口打断──▶ listening（不计数，优先听）
///   任意状态 ──stopConversation / 长按退出 / 达 maxRounds──▶ idle
///
/// 说明：
/// - 「3 秒无新声音自动结束说话」由 AudioCaptureManager 的 VAD 实现
///   （内部 silenceDuration=0.5s + 最少 12000 采样），本类直接复用，不重复造轮子。
/// - 朗读（TTS）由本类自己驱动（场景音量/打断需要）；
/// - 发送链路双模式：
///   - 独立路径（默认）：本类自己持有 OpenClawClient，走网关流式发送
///     （OpenClawClient.stream + model "openclaw:<agentId>"，与 SyncChatViewModel.send 同链路），
///     主页不依赖聊天页，没进过聊天也能用；
///   - 兼容路径（宿主注入了 chatViewModel）：复用 ChatViewModel 的 sendText + messages 轮询，
///     并持续抑制其自带朗读（详见 requestAgentReply）。
@Observable
@MainActor
final class VoiceAssistantViewModel {

    // MARK: - 状态（工程统一用 @Observable，等价任务要求的 @Published，供卡片绑定）

    /// 当前会话状态：idle / listening / thinking / speaking。
    private(set) var state: VoiceAssistantState = .idle

    /// 最近一次错误（展示在卡片或日志）。
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "语音助手", errorMessage)
            }
        }
    }

    /// 当前场景模式：卡片右上角按钮循环切换（normal/driving/night）。
    /// 本类用 UserDefaults 兜底持久化（voiceAssistant.sceneMode）；
    /// 若后续主智能体在 AppSettings 增加 voiceAssistantScene 字段，可改由设置存储承载。
    var sceneMode: VoiceSceneMode = .normal

    /// 已完成轮数（被打断不计入）。
    private(set) var roundCount = 0

    /// 本轮用户说的话（供 UI/调试展示）。
    private(set) var lastTranscript = ""

    /// 本轮智能体回复文本（供 UI/调试展示）。
    private(set) var lastReply = ""

    /// 连续对讲最大轮数：达到自动结束，防止无人值守死循环；
    /// 卡片同时支持「长按退出」随时手动结束。
    let maxRounds = 20

    // MARK: - 依赖

    private let audioCapture = AudioCaptureManager()
    private let audioPlayback = AudioPlaybackManager()
    private var transcriptionService: (any TranscriptionService)?
    private var speechService: (any SpeechService)?
    /// 设置存储：独立发送时读取网关地址/令牌/API 模式。
    private let settings: SettingsStore
    /// 兼容路径：宿主（主页/聊天页）可注入 ChatViewModel，走原有 sendText + 轮询发送。
    private var chatViewModel: ChatViewModel?
    /// 网关连接（可选）：当前独立发送走 OpenClawClient HTTP 流式，与 SyncChatViewModel.send
    /// 一致；保留该引用供后续 WebSocket 直连扩展。
    private let gatewayConnection: GatewayConnection?
    /// 目标智能体 ID：默认 "main"，或 settings 里的默认频道（唤醒频道/首个频道）的 agentId。
    private let agentId: String
    /// 独立发送链路持有的 OpenClawClient（与 SyncChatViewModel 同模式）。
    private let openClaw = OpenClawClient()
    /// 连续对讲内的上下文历史（独立路径；每轮结束后保留，最多 20 条）。
    private var conversationHistory: [Message] = []

    private var sessionTask: Task<Void, Never>?
    private var interruptedDuringSpeaking = false

    /// 主初始化：不依赖 ChatViewModel，语音助手可独立于聊天页工作。
    /// - Parameters:
    ///   - settings: 设置存储（网关地址/令牌/API 模式/STT 语言/TTS 参数）
    ///   - gatewayConnection: 可选网关连接（保留给后续 WebSocket 直连）
    ///   - agentId: 目标智能体 ID；传 nil 时取 settings 里的默认频道，兜底 "main"
    ///   - chatViewModel: 兼容路径：传入时复用原 sendText + 轮询发送链路
    init(
        settings: SettingsStore,
        gatewayConnection: GatewayConnection? = nil,
        agentId: String? = nil,
        chatViewModel: ChatViewModel? = nil
    ) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        self.agentId = agentId ?? Self.resolveDefaultAgentID(settings: settings)
        self.chatViewModel = chatViewModel
        self.sceneMode = Self.loadSceneMode()
    }

    /// 兼容旧调用方：仅传入 ChatViewModel（聊天页内嵌场景）。
    @available(*, deprecated, message: "请改用 init(settings:gatewayConnection:agentId:chatViewModel:)")
    convenience init(chatViewModel: ChatViewModel) {
        self.init(settings: SettingsStore(), chatViewModel: chatViewModel)
    }

    /// 由 App 层接线（与 ChatViewModel.configure 同模式），传入 STT/TTS 服务。
    func configure(transcription: (any TranscriptionService)?, speech: any SpeechService) {
        transcriptionService = transcription
        speechService = speech
    }

    /// 当前输入音量（VAD 平滑 RMS），供「说话」声波动画使用。
    var audioLevel: Float {
        audioCapture.currentLevel
    }

    var isActive: Bool {
        state != .idle
    }

    // MARK: - 生命周期

    /// 卡片点按入口：空闲 → 开始对讲；对讲中 → 结束。
    func toggle() {
        if state == .idle {
            startConversation()
        } else {
            stopConversation()
        }
    }

    /// 开始连续对讲。
    func startConversation() {
        guard state == .idle else { return }
        guard transcriptionService != nil else {
            errorMessage = "语音转文字服务未配置，请在设置中开启语音输入。"
            return
        }
        if let chatViewModel, chatViewModel.isConversationMode {
            errorMessage = "聊天页免提对话正在使用麦克风，请先退出。"
            return
        }
        // 与语音唤醒/免提对话共用麦克风：开始前先停唤醒，避免两个音频引擎抢麦。
        VoiceWakeCapability.shared.stopListening()

        roundCount = 0
        conversationHistory.removeAll()
        lastTranscript = ""
        lastReply = ""
        errorMessage = nil
        interruptedDuringSpeaking = false

        // 必须先启动录音引擎（麦克风采集 + VAD），再 enableVAD 接管；
        // 漏掉 startRecording 会导致引擎不跑：听不到说话、打断检测也失效。
        do {
            try audioCapture.startRecording()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            return
        }

        audioCapture.enableVAD(
            onUtterance: { [weak self] samples in
                Task { @MainActor in
                    self?.handleUtterance(samples)
                }
            },
            onAudioChunk: { [weak self] chunk in
                // TODO(主智能体)：若 STT 配成豆包，这里需把 chunk 喂给
                // `(self?.transcriptionService as? DoubaoSTTService)?.feedStreaming(samples: chunk)`，
                // 并在转写处改调 `finishStreaming()`（与 ChatViewModel.enterConversationMode 一致）。
                _ = chunk
            },
            onInterrupt: { [weak self] in
                Task { @MainActor in
                    self?.handleInterrupt()
                }
            }
        )
        state = .listening
        applyScreenAwakePolicy()
    }

    /// 结束连续对讲：停录音、停朗读、取消任务。
    func stopConversation() {
        sessionTask?.cancel()
        sessionTask = nil
        audioCapture.stopContinuousRecording()
        speechService?.stop()
        audioPlayback.stop()
        state = .idle
        applyScreenAwakePolicy()
    }

    /// 页面退出/App 生命周期兜底（幂等）。
    func stop() {
        stopConversation()
    }

    // MARK: - 场景模式

    /// 场景模式快速切换（卡片右上角小按钮）：normal → driving → night → normal 循环。
    func cycleSceneMode() {
        guard let idx = VoiceSceneMode.allCases.firstIndex(of: sceneMode) else {
            sceneMode = .normal
            return
        }
        let next = VoiceSceneMode.allCases[(idx + 1) % VoiceSceneMode.allCases.count]
        sceneMode = next
        Self.saveSceneMode(next)
        applyScreenAwakePolicy()
    }

    /// 按场景模式设置屏幕常亮（开车/夜间对讲期间常亮，空闲恢复），与场景快速切换联动。
    private func applyScreenAwakePolicy() {
        UIApplication.shared.isIdleTimerDisabled = state != .idle && sceneMode.keepsScreenAwake
    }

    private static let sceneModeDefaultsKey = "voiceAssistant.sceneMode"

    private static func loadSceneMode() -> VoiceSceneMode {
        guard let raw = UserDefaults.standard.string(forKey: sceneModeDefaultsKey),
              let mode = VoiceSceneMode(rawValue: raw) else {
            return .normal
        }
        return mode
    }

    private static func saveSceneMode(_ mode: VoiceSceneMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: sceneModeDefaultsKey)
    }

    /// 默认目标智能体：优先 settings 里「唤醒后进入的频道」（voiceWakeChannelID），
    /// 其次频道列表第一个频道；都没有则 "main"。
    private static func resolveDefaultAgentID(settings: SettingsStore) -> String {
        if let wakeChannelID = settings.settings.voiceWakeChannelID,
           let matched = ChannelStore.shared.channels.first(where: { $0.id.uuidString == wakeChannelID }) {
            return matched.agentId
        }
        if let first = ChannelStore.shared.channels.first {
            return first.agentId
        }
        return "main"
    }

    // MARK: - 对话循环

    /// VAD 检测到一次完整说话（停顿自动结束）后的处理。
    private func handleUtterance(_ samples: [Float]) {
        guard state == .listening else { return }
        audioCapture.pauseListening()
        state = .thinking

        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await transcribe(samples)
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    resumeNextRound()
                    return
                }
                lastTranscript = transcript

                let reply = try await requestAgentReply(transcript)
                guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    resumeNextRound()
                    return
                }
                lastReply = reply

                let finishedSpeaking = await speak(reply)
                try Task.checkCancellation()

                if !finishedSpeaking {
                    // 被打断：handleInterrupt 已停朗读并恢复聆听，直接结束本轮。
                    return
                }

                // 正常说完一轮：计入轮数，继续下一轮；达上限自动结束。
                roundCount += 1
                if roundCount >= maxRounds {
                    stopConversation()
                    return
                }
                resumeNextRound()
            } catch is CancellationError {
                // 手动退出/打断取消：静默，不报错。
            } catch {
                errorMessage = "语音助手出错了：\(AppErrorText.localized(error.localizedDescription))"
                // 单轮失败不结束会话，继续聆听下一句。
                resumeNextRound()
            }
        }
    }

    /// 进入下一轮监听。
    private func resumeNextRound() {
        guard state != .idle else { return }
        audioCapture.resumeListening()
        state = .listening
    }

    /// 转写：调 TranscriptionService.transcribe 拿文字。
    private func transcribe(_ samples: [Float]) async throws -> String {
        guard let stt = transcriptionService else {
            throw VoiceAssistantError.notConfigured("语音转文字服务未初始化")
        }
        // 豆包整段识别走协议标准方法；流式（边说边送）接入见 startConversation 的 TODO。
        return try await stt.transcribe(audioSamples: samples)
    }

    /// 发送给智能体并拿到完整回复文本。
    ///
    /// - 独立路径（无 chatViewModel）：本类自己持有 OpenClawClient 走网关流式发送
    ///   （OpenClawClient.stream + model "openclaw:<agentId>"，与 SyncChatViewModel.send 同链路），
    ///   不依赖聊天页，主页没进过聊天也能用。
    /// - 兼容路径（注入了 chatViewModel）：复用 ChatViewModel 的 sendText + messages 轮询，
    ///   并持续抑制其自带朗读（语音助手自己控制 TTS 场景音量/打断）。
    private func requestAgentReply(_ text: String) async throws -> String {
        if let chatViewModel {
            return try await requestAgentReplyViaChatViewModel(text, chatViewModel: chatViewModel)
        }
        return try await requestAgentReplyViaGateway(text)
    }

    /// 兼容路径：ChatViewModel sendText + 轮询 messages。
    private func requestAgentReplyViaChatViewModel(_ text: String, chatViewModel: ChatViewModel) async throws -> String {
        guard chatViewModel.state == .idle || chatViewModel.state == .speaking || chatViewModel.state == .streaming else {
            throw VoiceAssistantError.busy
        }

        let baselineCount = chatViewModel.messages.count
        chatViewModel.sendText(text)

        // ChatViewModel 在 voiceOutputEnabled=true 时会自带朗读；语音助手要自己控制
        // 朗读（场景音量/打断），这里持续抑制它的 TTS。注意 sendMessage 开头会重置
        // ttsStopped，所以要在流式开始后重复调用（见下方轮询）。
        chatViewModel.stopSpeaking()

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try Task.checkCancellation()

            // 流式开始后再次抑制自带朗读（sendMessage 已重置 ttsStopped）。
            if chatViewModel.state == .streaming || chatViewModel.state == .speaking {
                chatViewModel.stopSpeaking()
            }

            guard chatViewModel.messages.count >= baselineCount + 2 else {
                try await Task.sleep(nanoseconds: 150_000_000)
                continue
            }
            if let last = chatViewModel.messages.last {
                if last.role == .assistant, !last.isStreaming {
                    if !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return last.content
                    }
                    if last.sendError != nil {
                        throw VoiceAssistantError.emptyReply
                    }
                } else if last.role == .user, last.hasFailed {
                    // 失败时空 assistant 消息被移除，用户消息带 sendError。
                    throw VoiceAssistantError.emptyReply
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw VoiceAssistantError.timeout
    }

    /// 独立路径：OpenClawClient.stream 流式拿完整回复（纯文本，不朗读）。
    private func requestAgentReplyViaGateway(_ text: String) async throws -> String {
        guard settings.isConfigured else {
            throw VoiceAssistantError.notConfigured("请先在设置中配置 OpenClaw 网关。")
        }

        conversationHistory.append(Message(role: .user, content: text))
        trimConversationHistory()

        let token = OpenClawClient.resolveHTTPToken(
            settingsToken: settings.gatewayToken,
            gatewayURL: settings.settings.gatewayURL
        )
        let eventStream = openClaw.stream(
            messages: conversationHistory,
            gatewayURL: settings.settings.gatewayURL,
            token: token,
            model: "openclaw:\(agentId)",
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
                    throw VoiceAssistantError.timeout
                }
                switch event {
                case .textDelta(let delta):
                    reply += delta
                case .modelIdentified, .completed:
                    break
                }
            }
        } catch {
            // 发送失败/取消：不把失败消息留在上下文历史里，下一轮从干净上下文继续。
            removeConversationUserMessage(text)
            throw error
        }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removeConversationUserMessage(text)
            throw VoiceAssistantError.emptyReply
        }

        conversationHistory.append(Message(role: .assistant, content: trimmed))
        trimConversationHistory()
        return trimmed
    }

    /// 上下文历史只保留最近 20 条（约 10 轮），避免无限增长。
    private func trimConversationHistory() {
        if conversationHistory.count > 20 {
            conversationHistory.removeFirst(conversationHistory.count - 20)
        }
    }

    private func removeConversationUserMessage(_ text: String) {
        if let idx = conversationHistory.lastIndex(where: { $0.role == .user && $0.content == text }) {
            conversationHistory.remove(at: idx)
        }
    }

    /// 朗读回复。返回 true = 正常读完；false = 被用户打断。
    /// 朗读期间 VAD 引擎保持运行（pauseListening 只停说话采集，打断检测仍生效）。
    private func speak(_ text: String) async -> Bool {
        guard let tts = speechService else {
            // 无 TTS 配置：跳过朗读，直接视为读完（回复文本已留在 lastReply/聊天记录）。
            return true
        }

        do {
            try audioPlayback.start()
        } catch {
            LogCollector.record(module: "语音助手", "朗读启动失败：\(AppErrorText.localized(error.localizedDescription))")
            return true
        }
        applySceneVolume()

        interruptedDuringSpeaking = false
        audioCapture.pauseListening()
        state = .speaking

        do {
            for try await chunk in tts.streamSpeech(text: text) {
                try Task.checkCancellation()
                audioPlayback.enqueue(pcmData: chunk)
            }
            audioPlayback.markStreamingDone()
            await audioPlayback.waitUntilFinished()
        } catch is CancellationError {
            // 被打断/退出：静默结束。
        } catch {
            LogCollector.record(module: "语音助手", "朗读失败：\(AppErrorText.localized(error.localizedDescription))")
        }

        audioPlayback.stop()
        return !interruptedDuringSpeaking
    }

    /// 朗读期间用户开口（输入音量超阈值）→ 停止朗读、优先听。
    private func handleInterrupt() {
        guard state == .speaking else { return }
        interruptedDuringSpeaking = true
        sessionTask?.cancel()
        speechService?.stop()
        audioPlayback.stop()
        // 立即回聆听（resumeListening 的 800ms 预热会吞掉 TTS 回声尾巴）。
        audioCapture.resumeListening()
        state = .listening
    }

    /// 场景音量：夜间轻声（duckVolume 0.3），其余恢复 1.0。
    private func applySceneVolume() {
        if sceneMode.usesQuietVoice {
            audioPlayback.duckVolume()
        } else {
            audioPlayback.restoreVolume()
        }
    }
}
