import Foundation
import UIKit

/// 全局语音悬浮球 ViewModel（F4）：
/// 按住说话 → 松开转写（复用 AudioCaptureManager + TranscriptionService 只读引用，
/// 规则与 ClawTalkApp.configureServices / 全局语音输入一致：跟随设置 STT 提供商）。
@Observable
@MainActor
final class FloatingMicViewModel {
    private let settingsStore: SettingsStore
    private let audioCapture = AudioCaptureManager()
    private var transcriptionService: (any TranscriptionService)?
    private var levelTimer: Timer?
    private var recordingStart: Date?

    enum PanelState: Equatable {
        case idle
        case recording
        case transcribing
    }

    private(set) var state: PanelState = .idle
    var audioLevel: Float = 0
    var transcript = ""
    var errorMessage: String? {
        didSet { if let errorMessage { LogCollector.record(module: "悬浮球", errorMessage) } }
    }
    /// 识别完成回调（App 层可承接文本做后续动作）。
    var onTranscript: ((String) -> Void)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    // MARK: - 按住说话

    func startRecording() {
        guard state == .idle else { return }
        VoiceWakeCapability.shared.stopListening()
        errorMessage = nil
        do {
            try audioCapture.startRecording()
            recordingStart = Date()
            state = .recording
            startLevelTimer()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            state = .idle
        }
    }

    func stopRecordingAndProcess() {
        guard state == .recording else { return }
        stopLevelTimer()
        let samples = audioCapture.stopRecording()
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        recordingStart = nil
        // 与聊天页/语音日记同阈值：<0.5s 或样本过少视为误触
        guard duration >= 0.5, samples.count > 8000 else {
            state = .idle
            return
        }
        state = .transcribing
        Task {
            guard let stt = makeTranscriptionService() else {
                errorMessage = "语音输入已在设置中关闭，请到设置页开启后重试"
                state = .idle
                return
            }
            do {
                let text = try await stt.transcribe(audioSamples: samples)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "没有识别到内容，请再试一次"
                    state = .idle
                    return
                }
                transcript = trimmed
                onTranscript?(trimmed)
                state = .idle
            } catch {
                errorMessage = "转写失败：\(AppErrorText.localized(error.localizedDescription))"
                state = .idle
            }
        }
    }

    /// 取消未完成的录音（关闭面板/打断时调用）。
    func cancelRecording() {
        guard state == .recording else { return }
        stopLevelTimer()
        _ = audioCapture.stopRecording()
        recordingStart = nil
        state = .idle
    }

    func clearTranscript() {
        transcript = ""
    }

    func copyTranscript() {
        UIPasteboard.general.string = transcript
    }

    // MARK: - STT 工厂（与全局语音输入同规则）

    private func makeTranscriptionService() -> (any TranscriptionService)? {
        let settings = settingsStore.settings
        guard settings.voiceInputEnabled else { return nil }
        if let cached = transcriptionService { return cached }
        let service: any TranscriptionService
        switch settings.sttProvider {
        case .apple:
            service = AppleSTTService(language: settings.whisperLanguage)
        case .doubao:
            if let key = SecureStorage.shared.doubaoAPIKey, !key.isEmpty {
                service = DoubaoSTTService(apiKey: key, language: settings.whisperLanguage)
            } else {
                service = AppleSTTService(language: settings.whisperLanguage)
            }
        }
        transcriptionService = service
        return service
    }

    // MARK: - 电平轮询

    private func startLevelTimer() {
        stopLevelTimer()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                self.audioLevel = self.audioCapture.currentLevel
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
    }

    /// 会话结束后恢复语音唤醒监听（App 层已监听该通知）。
    func restoreWakeListening() {
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }
}
