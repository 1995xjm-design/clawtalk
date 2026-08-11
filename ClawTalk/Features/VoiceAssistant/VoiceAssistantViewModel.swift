import Foundation
import SwiftUI

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
/// - 朗读（TTS）由本类自己驱动（场景音量/打断需要），
///   智能体发送复用 ChatViewModel 公开 API（详见 requestAgentReply 的 TODO）。
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

    /// 当前场景模式：接线方（副主页/设置页）直接赋值；
    /// 持久化字段见 VoiceSceneMode.swift 底部 TODO（需主智能体在 AppSettings 加）。
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
    private let chatViewModel: ChatViewModel

    private var sessionTask: Task<Void, Never>?
    private var interruptedDuringSpeaking = false

    init(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
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
        guard !chatViewModel.isConversationMode else {
            errorMessage = "聊天页免提对话正在使用麦克风，请先退出。"
            return
        }
        // 与语音唤醒/免提对话共用麦克风：开始前先停唤醒，避免两个音频引擎抢麦。
        VoiceWakeCapability.shared.stopListening()

        roundCount = 0
        lastTranscript = ""
        lastReply = ""
        errorMessage = nil
        interruptedDuringSpeaking = false

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

        // TODO(主智能体)：sceneMode.keepsScreenAwake（开车/夜间）时建议接线处设置
        // `UIApplication.shared.isIdleTimerDisabled = true`，stopConversation 里恢复 false。
    }

    /// 结束连续对讲：停录音、停朗读、取消任务。
    func stopConversation() {
        sessionTask?.cancel()
        sessionTask = nil
        audioCapture.stopContinuousRecording()
        speechService?.stop()
        audioPlayback.stop()
        state = .idle
    }

    /// 页面退出/App 生命周期兜底（幂等）。
    func stop() {
        stopConversation()
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
    /// 复用 ChatViewModel 的发送链路（公开 API：sendText + messages 轮询）。
    /// TODO(主智能体)：更干净的做法是给 ChatViewModel 增加一个「纯文本发送、不朗读、
    /// 直接返回完整回复」的公开方法（如 `func sendForVoiceAssistant(_ text: String) async throws -> String`），
    /// 替换本方法的兼容路径（sendText + 轮询抑制自带朗读），避免双播/轮询开销。
    private func requestAgentReply(_ text: String) async throws -> String {
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
