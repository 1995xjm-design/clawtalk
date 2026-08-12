import SwiftUI
import Observation
import AVFoundation
import UIKit

// MARK: - 录音模式

/// 全局语音输入模式：短语音（按住说话）/ 长录音（点按开始结束）。
enum GlobalVoiceInputMode: String, CaseIterable, Identifiable {
    case short
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return "短语音"
        case .long: return "长录音"
        }
    }

    var hint: String {
        switch self {
        case .short: return "按住说话，松开识别（1–30 秒）"
        case .long: return "点按开始/结束，长录音 2–10 分钟，支持切后台继续"
        }
    }
}

// MARK: - 状态

enum GlobalVoiceInputState: Equatable {
    case idle
    case recording
    case transcribing
}

// MARK: - ViewModel

/// 全局语音输入 ViewModel（D1 底座）：
/// - 短语音：按住说话（AudioCaptureManager，30 秒自动截断）
/// - 长录音：点按开始/结束（LongAudioRecorder，AVAudioFile 流式写盘不堆内存，可切后台）
/// - 转写：复用现有 STT 栈（Apple / 豆包，跟随设置）；长录音按 50 秒分段拼接
@MainActor
@Observable
final class GlobalVoiceInputViewModel {
    private let settingsStore: SettingsStore
    private let audioCapture = AudioCaptureManager()
    private var longRecorder: LongAudioRecorder?
    private var transcriptionService: (any TranscriptionService)?
    private var levelTimer: Timer?
    private var recordingStart: Date?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    var mode: GlobalVoiceInputMode = .short
    private(set) var state: GlobalVoiceInputState = .idle
    var audioLevel: Float = 0
    var durationText: String = ""
    var waveformLevels: [Float] = []
    var transcript: String = ""
    var errorMessage: String?

    /// 识别完成回调（页面承接文本，例如预填目标功能）。
    var onTranscript: ((String, GlobalVoiceInputMode) -> Void)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    // MARK: - 短语音（按住说话）

    func startShortRecording() {
        guard state == .idle else { return }
        beginSession()
        do {
            try audioCapture.startRecording()
            recordingStart = Date()
            state = .recording
            startTimers()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            endSession()
        }
    }

    func stopShortRecording() {
        guard state == .recording else { return }
        stopTimers()
        let samples = audioCapture.stopRecording()
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        recordingStart = nil
        // 与聊天页/口述同阈值：<0.5s 或样本过少视为误触
        guard duration >= 0.5, samples.count > 8000 else {
            state = .idle
            endSession()
            return
        }
        transcribe(samples, chunked: false)
    }

    // MARK: - 长录音（点按开始/结束）

    func startLongRecording() {
        guard state == .idle else { return }
        beginSession()
        let recorder = LongAudioRecorder()
        do {
            try recorder.start()
            longRecorder = recorder
            recordingStart = Date()
            state = .recording
            waveformLevels = []
            startTimers()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            endSession()
        }
    }

    func stopLongRecording() {
        guard state == .recording, let recorder = longRecorder else { return }
        stopTimers()
        let samples = recorder.stop()
        longRecorder = nil
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        recordingStart = nil
        guard duration >= 2, !samples.isEmpty else {
            if duration < 2 {
                errorMessage = "录音太短（少于 2 秒），长录音建议录足 2–10 分钟"
            }
            state = .idle
            endSession()
            return
        }
        durationText = Self.formatDuration(duration)
        transcribe(samples, chunked: true)
    }

    /// 页面退出时丢弃未完成的录音（不转写、不保存）。
    func discard() {
        stopTimers()
        if state == .recording {
            if longRecorder != nil {
                _ = longRecorder?.stop()
                longRecorder = nil
            } else {
                _ = audioCapture.stopRecording()
            }
        }
        state = .idle
        recordingStart = nil
        endSession()
    }

    // MARK: - 转写（长录音分段拼接）

    private func transcribe(_ samples: [Float], chunked: Bool) {
        state = .transcribing
        errorMessage = nil
        let pieces = chunked ? Self.chunk(samples) : [samples]
        Task { [weak self] in
            defer { self?.endSession() }
            guard let self else { return }
            guard let stt = self.makeTranscriptionService() else {
                self.errorMessage = "语音输入已在设置中关闭，请到设置页开启后重试"
                self.state = .idle
                return
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
                    LogCollector.record(module: "全局语音输入", "分段 \(index) 转写失败：\(error.localizedDescription)")
                }
            }
            let joined = results.joined(separator: "。").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else {
                self.errorMessage = failed > 0 ? "转写失败：没有识别到内容，请再试一次" : "没有识别到内容，请再试一次"
                self.state = .idle
                return
            }
            self.transcript = joined
            self.onTranscript?(joined, self.mode)
            self.state = .idle
        }
    }

    /// 长录音按 50 秒一段切分（16kHz 单声道），逐段转写后拼接，控制单次识别长度。
    private static func chunk(_ samples: [Float]) -> [[Float]] {
        let chunkSize = 16000 * 50
        guard samples.count > chunkSize else { return [samples] }
        var result: [[Float]] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            result.append(Array(samples[offset..<end]))
            offset = end
        }
        return result
    }

    // MARK: - STT 工厂（与文档口述/会议纪要同规则）

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

    // MARK: - 电平/时长轮询

    private func startTimers() {
        stopTimers()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let level = self.longRecorder?.currentLevel ?? self.audioCapture.currentLevel
                self.audioLevel = level
                if self.mode == .long, self.state == .recording {
                    self.waveformLevels.append(level)
                    if self.waveformLevels.count > 48 {
                        self.waveformLevels.removeFirst(self.waveformLevels.count - 48)
                    }
                }
                guard let start = self.recordingStart, self.state == .recording else { return }
                let elapsed = Date().timeIntervalSince(start)
                self.durationText = Self.formatDuration(elapsed)
                if self.mode == .short, elapsed > 30 {
                    self.stopShortRecording()
                }
                if self.mode == .long, elapsed > 600 {
                    self.stopLongRecording()
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

    private func endSession() {
        restoreWakeListening()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func restoreWakeListening() {
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - 长录音录制器（AVAudioFile 流式写盘）

/// 长录音录制器：AVAudioEngine + AVAudioFile 流式写盘（不堆内存），
/// 录音期间保持音频会话活跃 + 后台任务，切后台继续（依赖 App 的 audio 后台模式）。
private final class LongAudioRecorder {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private let writeQueue = DispatchQueue(label: "clawtalk.long-audio-write")
    private(set) var isRecording = false
    private(set) var currentLevel: Float = 0

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        try? inputNode.setVoiceProcessingEnabled(true)
        let format = inputNode.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        self.file = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.currentLevel = Self.instantLevel(of: buffer)
            self.writeQueue.async { [weak self] in
                guard let self, let file = self.file else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    LogCollector.record(module: "长录音", "写盘失败：\(error.localizedDescription)")
                }
            }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        isRecording = true
    }

    /// 停止录音：摘 tap → 刷完写盘队列 → 读出 16kHz 单声道 Float32 样本。
    func stop() -> [Float] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRecording = false
        currentLevel = 0
        let url = file?.url
        file = nil
        // 等写盘队列排空，避免读到未写完的文件
        writeQueue.sync {}
        guard let url else { return [] }
        defer { try? FileManager.default.removeItem(at: url) }
        return readSamples16k(from: url)
    }

    // MARK: - 工具

    private static func instantLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Double = 0
        let count = Int(buffer.frameLength)
        for i in 0..<count {
            let v = Double(data[i])
            sum += v * v
        }
        return Float(sqrt(sum / Double(count)))
    }

    private func readSamples16k(from url: URL) -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            return []
        }
        do {
            try audioFile.read(into: buffer)
        } catch {
            return []
        }
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        let captured = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return Self.resampleTo16k(captured, from: audioFile.processingFormat.sampleRate)
    }

    private static func resampleTo16k(_ samples: [Float], from sampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let outputRate = 16000.0
        if abs(sampleRate - outputRate) < 0.5 {
            return samples
        }
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return samples
        }
        let ratio = outputRate / sampleRate
        let outputLength = Int(Double(samples.count) * ratio)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outputLength)) else {
            return samples
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            inputBuffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: samples.count)
        }
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            status.pointee = .haveData
            return inputBuffer
        }
        guard error == nil else { return samples }
        return Array(UnsafeBufferPointer(start: outputBuffer.floatChannelData?[0], count: Int(outputBuffer.frameLength)))
    }
}

// MARK: - 组件视图

/// 全局语音输入组件：大语音按钮 + 状态显示，供主页各卡片页嵌入。
struct GlobalVoiceInput: View {
    @State private var viewModel: GlobalVoiceInputViewModel
    @State private var isPressed = false
    @State private var holdTimer: Task<Void, Never>?

    private let buttonSize: CGFloat = 72
    private let holdThreshold: UInt64 = 300_000_000

    init(settingsStore: SettingsStore, onTranscript: ((String, GlobalVoiceInputMode) -> Void)? = nil) {
        let vm = GlobalVoiceInputViewModel(settingsStore: settingsStore)
        vm.onTranscript = onTranscript
        _viewModel = State(initialValue: vm)
    }

    var body: some View {
        VStack(spacing: 14) {
            Picker("录音方式", selection: $viewModel.mode) {
                ForEach(GlobalVoiceInputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            recordButton

            statusArea
        }
        .padding(.vertical, 4)
        .onDisappear {
            holdTimer?.cancel()
            holdTimer = nil
            viewModel.discard()
        }
    }

    // MARK: - 录音按钮

    private var recordButton: some View {
        ZStack {
            if viewModel.state == .recording {
                Circle()
                    .stroke(Color.openClawRed.opacity(0.25), lineWidth: 3)
                    .frame(
                        width: buttonSize + 16 + CGFloat(viewModel.audioLevel * 56),
                        height: buttonSize + 16 + CGFloat(viewModel.audioLevel * 56)
                    )
                    .animation(.easeOut(duration: 0.08), value: viewModel.audioLevel)

                if viewModel.mode == .long {
                    Circle()
                        .trim(from: 0, to: 0.65)
                        .stroke(Color.openClawRed.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: buttonSize + 10, height: buttonSize + 10)
                        .rotationEffect(.degrees(recordingRingAngle))
                        .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: recordingRingAngle)
                }
            }

            Circle()
                .fill(buttonColor)
                .frame(width: buttonSize, height: buttonSize)
                .shadow(color: buttonColor.opacity(0.4), radius: isPressed ? 4 : 8, y: isPressed ? 1 : 3)
                .scaleEffect(isPressed ? 0.9 : 1.0)

            buttonIcon
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: buttonSize + 60, height: buttonSize + 60)
        .contentShape(Circle())
        .gesture(recordGesture)
        .disabled(viewModel.state == .transcribing)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPressed)
        .accessibilityLabel(accessibilityLabel)
    }

    private var recordingRingAngle: Double {
        viewModel.state == .recording ? 360 : 0
    }

    private var buttonColor: Color {
        switch viewModel.state {
        case .idle: return .openClawRed
        case .recording: return .red
        case .transcribing: return .openClawRed.opacity(0.5)
        }
    }

    @ViewBuilder
    private var buttonIcon: some View {
        switch viewModel.state {
        case .idle:
            Image(systemName: viewModel.mode == .long ? "record.circle" : "mic.fill")
        case .recording:
            Image(systemName: viewModel.mode == .long ? "stop.fill" : "mic.fill")
                .symbolEffect(.pulse)
        case .transcribing:
            Image(systemName: "waveform")
        }
    }

    private var accessibilityLabel: String {
        switch viewModel.state {
        case .idle: return viewModel.mode == .long ? "点按开始长录音" : "按住说话"
        case .recording: return "正在录音，点按/松开结束"
        case .transcribing: return "正在转写"
        }
    }

    // MARK: - 手势（短按说话 / 长点按开关）

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                switch viewModel.mode {
                case .short:
                    guard !isPressed, viewModel.state == .idle else { return }
                    isPressed = true
                    holdTimer = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: holdThreshold)
                        guard !Task.isCancelled, isPressed else { return }
                        viewModel.startShortRecording()
                    }
                case .long:
                    if viewModel.state == .idle {
                        viewModel.startLongRecording()
                    } else if viewModel.state == .recording {
                        viewModel.stopLongRecording()
                    }
                }
            }
            .onEnded { _ in
                holdTimer?.cancel()
                holdTimer = nil
                guard viewModel.mode == .short, isPressed else { return }
                isPressed = false
                if viewModel.state == .recording {
                    viewModel.stopShortRecording()
                }
            }
    }

    // MARK: - 状态区

    @ViewBuilder
    private var statusArea: some View {
        VStack(spacing: 8) {
            switch viewModel.state {
            case .idle:
                Text(viewModel.mode.hint)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            case .recording:
                VStack(spacing: 6) {
                    Text(viewModel.mode == .long ? "正在录音 · \(viewModel.durationText)" : "正在录音… 松开结束")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.openClawRed)
                    if viewModel.mode == .long, !viewModel.waveformLevels.isEmpty {
                        waveformBars
                    }
                }
            case .transcribing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.mode == .long ? "转写中…（长录音按段拼接）" : "转写中…")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }

            if !viewModel.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("识别结果", systemImage: "text.bubble.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("清空") {
                            viewModel.transcript = ""
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Text(viewModel.transcript)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// 长录音波形条：随环境音量起伏（数据来自录音电平采样）。
    private var waveformBars: some View {
        HStack(spacing: 3) {
            ForEach(viewModel.waveformLevels.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.openClawRed.opacity(0.7))
                    .frame(width: 3, height: max(6, min(40, CGFloat(viewModel.waveformLevels[index]) * 90)))
            }
        }
        .frame(height: 40)
        .animation(.linear(duration: 0.1), value: viewModel.waveformLevels)
    }
}
