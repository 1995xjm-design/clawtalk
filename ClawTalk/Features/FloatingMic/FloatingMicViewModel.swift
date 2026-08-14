import Foundation
import UIKit

/// 全局语音悬浮球 ViewModel（F4）：
/// 按住说话 → 松开转写（复用统一语音输入状态机，
/// 规则与 ClawTalkApp.configureServices / 全局语音输入一致：跟随设置 STT 提供商）。
@Observable
@MainActor
final class FloatingMicViewModel {
    private let settingsStore: SettingsStore
    /// 语音输入统一状态机（录音/STT/会话生命周期，规则与全局语音输入一致）
    private let voiceInput: VoiceInputStateMachine

    enum PanelState: Equatable {
        case idle
        case recording
        case transcribing
    }

    private(set) var state: PanelState = .idle
    var audioLevel: Float { voiceInput.audioLevel }
    var transcript = ""
    var errorMessage: String? {
        didSet { if let errorMessage { LogCollector.record(module: "悬浮球", errorMessage) } }
    }
    /// 识别完成回调（App 层可承接文本做后续动作）。
    var onTranscript: ((String) -> Void)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.voiceInput = VoiceInputStateMachine(settingsStore: settingsStore)
    }

    // MARK: - 按住说话

    func startRecording() {
        guard state == .idle else { return }
        // 统一走语音输入状态机（录音前状态机会先停语音唤醒）
        errorMessage = nil
        voiceInput.startShort()
        if voiceInput.isCapturing {
            state = .recording
        } else if let error = voiceInput.errorMessage {
            errorMessage = error
        }
    }

    func stopRecordingAndProcess() {
        guard state == .recording else { return }
        // 统一走语音输入状态机：误触（<0.5s 或样本过少）由状态机判弃并恢复会话
        guard let capture = voiceInput.finishShortCapture() else {
            state = .idle
            return
        }
        state = .transcribing
        Task {
            defer { voiceInput.endSession() }
            guard let text = await voiceInput.transcribe(capture.samples) else {
                if let error = voiceInput.errorMessage {
                    errorMessage = error
                }
                state = .idle
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                errorMessage = "没有识别到内容，请再试一次"
                state = .idle
                return
            }
            transcript = trimmed
            onTranscript?(trimmed)
            state = .idle
        }
    }

    /// 取消未完成的录音（关闭面板/打断时调用）。
    func cancelRecording() {
        guard state == .recording else { return }
        voiceInput.cancel()
        state = .idle
    }

    func clearTranscript() {
        transcript = ""
    }

    func copyTranscript() {
        UIPasteboard.general.string = transcript
    }

    /// 会话结束后恢复语音唤醒监听（App 层已监听该通知，委托状态机）。
    func restoreWakeListening() {
        voiceInput.endSession()
    }
}
