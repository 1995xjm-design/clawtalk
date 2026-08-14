import Foundation
import Observation
import AVFoundation
import UIKit

/// 语音输入状态机（主 App 统一 Core）：
/// 短语音（按住说话）/ 长录音（点按开始结束）/ 按住上滑切长录音 / 取消 / 转写（STT），
/// 供 WeChatInputBar（频道输入栏微信弧形）、GlobalVoiceInputEmbedded（各功能页底部录音区）、
/// 各功能页旧录音按钮复用；录音/阈值/时长上限/转写分段/会话生命周期与旧实现完全一致。
///
/// 键盘包（KeyboardPackages/HamsterKeyboardKit 的 ClawPanelOverlayView 波形面板）与主 App
/// 分属不同进程/包，保持独立，不强行合并（TODO：后续如需统一走共享包）。
@MainActor
@Observable
final class VoiceInputStateMachine {
    private let settingsStore: SettingsStore?
    private let audioCapture = AudioCaptureManager()
    private var longRecorder: LongAudioRecorder?
    private var transcriptionService: (any TranscriptionService)?
    private var levelTimer: Timer?
    private var recordingStart: Date?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// 短语音上滑切长录音时保留已录短样本，拼到长录音开头（切换不丢内容）。
    private var pendingShortSamples: [Float] = []

    var mode: VoiceInputMode = .short
    private(set) var phase: VoiceInputPhase = .idle
    var audioLevel: Float = 0
    var durationText: String = ""
    var waveformLevels: [Float] = []
    var transcript: String = ""
    var errorMessage: String?

    /// 识别完成回调（页面承接文本，例如预填目标功能）。
    var onTranscript: ((String, VoiceInputMode) -> Void)?
    /// 阶段变化回调（页面同步自己的 UI 状态，如聊天页 ChatState）。
    var onPhaseChange: ((VoiceInputPhase) -> Void)?

    /// - Parameter settingsStore: STT 工厂依赖；传 nil 时转写必须显式传 service（自带 STT 的入口）。
    init(settingsStore: SettingsStore? = nil) {
        self.settingsStore = settingsStore
    }

    var isCapturing: Bool { phase == .recording }

    // MARK: - 短语音（按住说话）

    func startShort() {
        guard phase == .idle else { return }
        guard ensureMicPermission() else { return }
        beginSession()
        do {
            try audioCapture.startRecording()
            recordingStart = Date()
            setPhase(.recording)
            startTimers()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            endSession()
        }
    }

    /// 结束短语音并自动转写（松开识别）。
    func finishShort() {
        guard let capture = finishShortCapture() else { return }
        runTranscription(samples: capture.samples, chunked: false, using: nil)
    }

    /// 结束短语音捕获（不自动转写）：返回样本与时长，由调用方自定义后续流程；
    /// 过短（<0.5s 或样本过少）视为误触，返回 nil（内部已结束会话）。
    func finishShortCapture() -> VoiceInputCapture? {
        guard phase == .recording, longRecorder == nil else { return nil }
        stopTimers()
        let samples = audioCapture.stopRecording()
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        recordingStart = nil
        guard duration >= 0.5, samples.count > 8000 else {
            setPhase(.idle)
            endSession()
            return nil
        }
        setPhase(.idle)
        return VoiceInputCapture(samples: samples, duration: duration)
    }

    // MARK: - 短语音 → 长录音切换（按住上滑）

    /// 按住说话时上滑切长录音：收下已录短样本，启动流式写盘的长录音；
    /// 松开手指后录音继续（锁定模式），点按按钮或 60 分钟上限时结束。
    func switchToLong() {
        guard phase == .recording, mode == .short, longRecorder == nil else { return }
        stopTimers()
        let shortSamples = audioCapture.stopRecording()
        if !shortSamples.isEmpty {
            pendingShortSamples = shortSamples
        }
        let recorder = LongAudioRecorder()
        do {
            try recorder.start()
            longRecorder = recorder
            recordingStart = Date()
            mode = .long
            waveformLevels = []
            setPhase(.recording)
            startTimers()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            setPhase(.idle)
            endSession()
        }
    }

    // MARK: - 长录音（点按开始/结束）

    func startLong() {
        guard phase == .idle else { return }
        guard ensureMicPermission() else { return }
        beginSession()
        let recorder = LongAudioRecorder()
        do {
            try recorder.start()
            longRecorder = recorder
            recordingStart = Date()
            setPhase(.recording)
            waveformLevels = []
            startTimers()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            endSession()
        }
    }

    /// 结束长录音并自动转写（分段拼接）。
    func finishLong() {
        guard let capture = finishLongCapture() else { return }
        runTranscription(samples: capture.samples, chunked: true, using: nil)
    }

    /// 结束长录音捕获（不自动转写）：短于 2 秒视为无效（返回 nil 并提示），
    /// 上滑保留的短样本自动拼到长录音开头。
    func finishLongCapture() -> VoiceInputCapture? {
        guard phase == .recording, let recorder = longRecorder else { return nil }
        stopTimers()
        var samples = recorder.stop()
        longRecorder = nil
        if !pendingShortSamples.isEmpty {
            samples = pendingShortSamples + samples
            pendingShortSamples = []
        }
        mode = .short
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        recordingStart = nil
        guard duration >= 2, !samples.isEmpty else {
            if duration < 2 {
                errorMessage = "录音太短（少于 2 秒），长录音最长可录 60 分钟"
            }
            setPhase(.idle)
            endSession()
            return nil
        }
        durationText = Self.formatDuration(duration)
        setPhase(.idle)
        return VoiceInputCapture(samples: samples, duration: duration)
    }

    /// 取消当前录音（丢弃样本，不转写不保存），恢复会话。
    func cancel() {
        if phase == .recording {
            if longRecorder != nil {
                _ = longRecorder?.stop()
                longRecorder = nil
            } else {
                _ = audioCapture.stopRecording()
            }
        }
        stopTimers()
        pendingShortSamples = []
        recordingStart = nil
        setPhase(.idle)
        endSession()
    }

    /// 页面退出时丢弃未完成的录音（不转写、不保存）。
    func discard() {
        cancel()
    }

    /// 自定义流程在转写/发送完成后显式调用：恢复唤醒监听 + 结束后台任务。
    func endSession() {
        restoreWakeListening()
        endBackgroundTask()
    }

    // MARK: - 转写

    /// 共享转写：按设置创建 STT（或使用注入 service），长录音按 50 秒分段拼接；
    /// 成功返回去空白后的文本；失败/无内容设置 errorMessage 并返回 nil。
    func transcribe(
        _ samples: [Float],
        chunked: Bool = false,
        using service: (any TranscriptionService)? = nil
    ) async -> String? {
        errorMessage = nil
        let pieces = chunked ? VoiceInputSTTFactory.chunk(samples) : [samples]
        guard let stt = service ?? makeTranscriptionService() else {
            errorMessage = "语音输入已在设置中关闭，请到设置页开启后重试"
            return nil
        }
        var results: [String] = []
        var failed = 0
        for (index, chunk) in pieces.enumerated() {
            do {
                let text = try await stt.transcribe(audioSamples: chunk)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    results.append(trimmed)
                }
            } catch {
                failed += 1
                LogCollector.record(module: "语音输入", "分段 \(index) 转写失败：\(error.localizedDescription)")
            }
        }
        let joined = results.joined(separator: "。").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            errorMessage = failed > 0 ? "转写失败：没有识别到内容，请再试一次" : "没有识别到内容，请再试一次"
            return nil
        }
        return joined
    }

    /// 设置页切换 STT 提供商后由外部调用，重建服务（等价于 App 层 reconfigureServices）。
    func rebuildSTTService() {
        transcriptionService = nil
    }

    // MARK: - STT 工厂（与 ClawTalkApp.configureServices 同规则）

    private func makeTranscriptionService() -> (any TranscriptionService)? {
        guard let settingsStore else { return nil }
        if let cached = transcriptionService { return cached }
        let service = VoiceInputSTTFactory.make(settingsStore: settingsStore)
        transcriptionService = service
        return service
    }

    // MARK: - 电平/时长轮询

    private func startTimers() {
        stopTimers()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let level = self.longRecorder?.currentLevel ?? self.audioCapture.currentLevel
                self.audioLevel = level
                if self.mode == .long, self.phase == .recording {
                    self.waveformLevels.append(level)
                    if self.waveformLevels.count > 48 {
                        self.waveformLevels.removeFirst(self.waveformLevels.count - 48)
                    }
                }
                guard let start = self.recordingStart, self.phase == .recording else { return }
                let elapsed = Date().timeIntervalSince(start)
                self.durationText = Self.formatDuration(elapsed)
                if self.mode == .short, elapsed > 60 {
                    self.finishShort()
                }
                if self.mode == .long, elapsed > 3600 {
                    self.finishLong()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopTimers() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
    }

    // MARK: - 会话生命周期

    private func beginSession() {
        VoiceWakeCapability.shared.stopListening()
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "clawtalk-global-voice") { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func restoreWakeListening() {
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }

    // MARK: - 麦克风权限

    private func ensureMicPermission() -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            errorMessage = "需要麦克风权限：请到 系统设置 → 隐私与安全性 → 麦克风 开启 ClawTalk 后重试。"
            return false
        case .undetermined:
            // 首次使用：弹系统授权框；授权后再点一次即可开始。
            AVAudioApplication.requestRecordPermission { granted in
                if !granted {
                    Task { @MainActor in
                        LogCollector.record(module: "语音输入", "用户拒绝麦克风权限")
                    }
                }
            }
            errorMessage = "请允许麦克风权限后再次点击开始。"
            return false
        @unknown default:
            return true
        }
    }

    // MARK: - 内部

    private func setPhase(_ newPhase: VoiceInputPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        onPhaseChange?(newPhase)
    }

    private func runTranscription(
        samples: [Float],
        chunked: Bool,
        using service: (any TranscriptionService)?
    ) {
        setPhase(.transcribing)
        errorMessage = nil
        Task { [weak self] in
            defer { self?.endSession() }
            guard let self else { return }
            guard let joined = await self.transcribe(samples, chunked: chunked, using: service) else {
                self.setPhase(.idle)
                return
            }
            self.transcript = joined
            self.onTranscript?(joined, self.mode)
            self.setPhase(.idle)
        }
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

#if DEBUG
    /// Test seam: enter the recording state without mic permission/hardware (DEBUG builds only).
    /// Lets unit tests exercise the idle -> recording -> stop/discard state machine.
    func beginRecordingForTesting() {
        setPhase(.recording)
        recordingStart = Date()
    }
#endif
}
