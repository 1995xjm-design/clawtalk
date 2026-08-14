import Foundation
import SwiftUI
import Observation
import AVFoundation

/// 录音纪要页状态。
enum MeetingRecorderState: Equatable {
    case idle
    case recording
    case transcribing
    case organizing
}

/// 会议纪要录音页 ViewModel：
/// 按住说话（AudioCaptureManager）→ STT 转写（按 SettingsStore.sttProvider 选服务）
/// → 展示原始转写（可编辑）+「整理纪要」（AI 优先，失败本地规则降级并诚实标注）
/// → 存 MeetingStore。
@Observable
@MainActor
final class MeetingRecorderViewModel {
    // MARK: - 依赖（现有语音栈/网关，只读引用）

    private let settingsStore: SettingsStore
    let meetingStore: MeetingStore
    private let audioCapture = AudioCaptureManager()
    private var transcriptionService: (any TranscriptionService)?
    private var levelTimer: Timer?
    private var recordingStart: Date?

    // MARK: - UI 状态

    private(set) var state: MeetingRecorderState = .idle
    var audioLevel: Float = 0
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "会议纪要", errorMessage)
            }
        }
    }
    /// 原始转写（用户可编辑后整理）
    var transcript: String = ""
    /// 会议标题（可编辑，空则 AI/本地规则生成）
    var meetingTitle: String = ""
    /// 参与者输入（逗号/顿号/空格分隔）
    var participantsInput: String = ""
    /// 整理完成后的纪要（驱动详情 sheet）
    var savedNote: MeetingNote?
    /// 本次录音存档文件名（转写成功后随纪要保存，可回放）
    private(set) var pendingAudioFileName: String?
    /// 整理来源说明（诚实：AI 整理 / 本地整理（未接 AI）及原因）
    var organizationNotice: String?

    var isOrganizing: Bool {
        state == .organizing
    }

    init(settingsStore: SettingsStore, meetingStore: MeetingStore) {
        self.settingsStore = settingsStore
        self.meetingStore = meetingStore
    }

    // MARK: - 录音（与语音日记同模式）

    func startRecording() {
        guard state == .idle else { return }
        VoiceWakeCapability.shared.stopListening()
        errorMessage = nil
        organizationNotice = nil
        do {
            try audioCapture.startRecording()
            recordingStart = Date()
            state = .recording
            startLevelTimer()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            restoreWakeListening()
        }
    }

    func stopRecordingAndTranscribe() {
        guard state == .recording else { return }
        stopLevelTimer()
        let samples = audioCapture.stopRecording()

        // 与聊天页同阈值：<0.5s 或样本过少视为误触
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        guard duration >= 0.5, samples.count > 8000 else {
            state = .idle
            restoreWakeListening()
            return
        }

        // 录音存档：保存 16kHz WAV 到 Application Support，供纪要回放
        pendingAudioFileName = Self.saveAudioArchive(samples)

        state = .transcribing
        Task {
            defer { restoreWakeListening() }
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
                if meetingTitle.isEmpty {
                    meetingTitle = Self.defaultTitle(from: trimmed, date: recordingStart ?? Date())
                }
                state = .idle
            } catch {
                errorMessage = "转写失败：\(AppErrorText.localized(error.localizedDescription))"
                state = .idle
            }
        }
    }

    /// 页面退出时丢弃未完成的录音（不转写、不保存）。
    func discardActiveRecording() {
        guard state == .recording else { return }
        stopLevelTimer()
        _ = audioCapture.stopRecording()
        state = .idle
        restoreWakeListening()
    }

    // MARK: - 整理纪要

    func organizeMeeting() {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "还没有转写内容，先录一段会议"
            return
        }
        guard state == .idle else { return }
        state = .organizing
        errorMessage = nil
        organizationNotice = nil

        let participants = parseParticipants(participantsInput)
        let date = recordingStart ?? Date()
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let result = await MeetingOrganizer.organize(
                transcript: trimmed,
                title: title.isEmpty ? nil : title,
                participants: participants,
                date: date,
                audioFileName: pendingAudioFileName,
                settings: settingsStore
            )
            meetingStore.add(result.note)
            savedNote = result.note
            pendingAudioFileName = nil
            if result.usedFallback {
                organizationNotice = result.fallbackReason.map { "\($0)，已改用本地规则整理" }
                    ?? "本次为本地规则整理（未接 AI）"
            } else {
                organizationNotice = "AI 整理完成"
            }
            state = .idle
        }
    }

    func clearTranscript() {
        transcript = ""
        meetingTitle = ""
        participantsInput = ""
        organizationNotice = nil
        savedNote = nil
        errorMessage = nil
    }

    /// 设置里切换 STT 提供商后由外部调用，重建服务。
    func rebuildSTTService() {
        transcriptionService = nil
    }

    // MARK: - STT 服务工厂（与 VoiceDiaryViewModel 同规则）

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

    // MARK: - 工具

    private func parseParticipants(_ input: String) -> [String] {
        input
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: " ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }


    /// 保存录音存档：16kHz 单声道 Float32 样本 -> WAV 文件（Application Support/ClawTalk/MeetingAudio/）。
    private static func saveAudioArchive(_ samples: [Float]) -> String? {
        guard !samples.isEmpty else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        let dir = base.appendingPathComponent("ClawTalk/MeetingAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = "meeting-\(UUID().uuidString).wav"
        let url = dir.appendingPathComponent(fileName)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            guard let basePtr = ptr.baseAddress else { return }
            buffer.floatChannelData?[0].update(from: basePtr, count: samples.count)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return fileName
        } catch {
            LogCollector.record(module: "会议纪要", "录音存档保存失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static func defaultTitle(from transcript: String, date: Date) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix(20))
        let title = prefix.count < trimmed.count ? prefix + "…" : prefix
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: date)) 会议：" + title
    }

    // MARK: - 录音电平轮询（驱动外圈脉冲动画）

    private func startLevelTimer() {
        stopLevelTimer()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
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

    /// 录音/转写结束后恢复语音唤醒监听（App 层已监听该通知）。
    private func restoreWakeListening() {
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }
}

/// 会议纪要录音页：
/// - 顶部标题/参与者输入框 + 原始转写（可编辑）
/// - 底部按住说话录音按钮，松开后 STT 转写
/// - 有转写后显示「整理纪要」按钮；AI 失败自动本地规则降级并诚实标注
/// - 整理完成弹出纪要详情（可一键把待办加入提醒）
struct MeetingRecorderView: View {
    @State private var viewModel: MeetingRecorderViewModel
    var onBack: (() -> Void)?

    private let settingsStore: SettingsStore

    // 按住说话手势状态（参考 VoiceDiaryView）
    @State private var isPressed = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var isHolding = false
    @State private var showHoldHint = false

    private let hapticsEnabled: Bool
    private let recordButtonSize: CGFloat = 72
    /// 按住多久算开始录音（0.3 秒，与 VoiceDiaryView 一致）
    private let holdThreshold: UInt64 = 300_000_000

    init(
        settingsStore: SettingsStore,
        meetingStore: MeetingStore,
        onBack: (() -> Void)? = nil
    ) {
        self.settingsStore = settingsStore
        _viewModel = State(initialValue: MeetingRecorderViewModel(
            settingsStore: settingsStore,
            meetingStore: meetingStore
        ))
        self.onBack = onBack
        self.hapticsEnabled = settingsStore.settings.hapticsEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider().opacity(0.3)
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.3)
            bottomArea
        }
        .background(Color(.systemBackground))
        .onDisappear { viewModel.discardActiveRecording() }
        .sheet(item: $viewModel.savedNote) { note in
            NavigationStack {
                MeetingDetailView(note: note, store: viewModel.meetingStore)
            }
        }
    }

    // MARK: - 导航栏

    private var navBar: some View {
        ZStack {
            Text("会议纪要")
                .font(.headline)
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "xmark")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Color(.systemGray5), in: Circle())
                    }
                    .accessibilityLabel("关闭")
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 52)
    }

    // MARK: - 内容区（标题/参与者/原始转写）

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("会议标题（可编辑）", text: $viewModel.meetingTitle)
                    .font(.headline)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )

                TextField("参与者（逗号/顿号分隔，可编辑）", text: $viewModel.participantsInput)
                    .font(.subheadline)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )

                transcriptSection
            }
            .padding(16)
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("原始转写")
                    .font(.headline)
                Spacer()
                if !viewModel.transcript.isEmpty {
                    Button("清空") { viewModel.clearTranscript() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("按住底部麦克风录音，松开后自动转写。转写后可以手动修改，再点「整理纪要」。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
            } else {
                TextEditor(text: $viewModel.transcript)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
            }
        }
    }

    // MARK: - 底部：整理按钮 + 录音区

    private var bottomArea: some View {
        VStack(spacing: 12) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if let notice = viewModel.organizationNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    viewModel.organizeMeeting()
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isOrganizing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(viewModel.isOrganizing ? "整理中…" : "整理纪要")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(viewModel.isOrganizing ? Color.gray : Color.indigo)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(viewModel.isOrganizing)
                .padding(.horizontal, 16)
            }

            recordArea
        }
        .padding(.vertical, 10)
    }

    private var recordArea: some View {
        GlobalVoiceInputEmbedded(settingsStore: settingsStore) { text, _ in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            viewModel.transcript = trimmed
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.state {
        case .idle:
            Text(showHoldHint ? "按住说话，松开结束" : "按住说话，录完松开")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(showHoldHint ? Color.openClawRed : .secondary)
        case .recording:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在录音… 松开结束")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.openClawRed)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("转写中…")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        case .organizing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("整理中…（AI 失败会自动用本地规则）")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 按住说话按钮

    private var recordButton: some View {
        ZStack {
            if viewModel.state == .recording {
                Circle()
                    .stroke(Color.openClawRed.opacity(0.25), lineWidth: 3)
                    .frame(
                        width: recordButtonSize + 18 + CGFloat(viewModel.audioLevel * 60),
                        height: recordButtonSize + 18 + CGFloat(viewModel.audioLevel * 60)
                    )
                    .animation(.easeOut(duration: 0.08), value: viewModel.audioLevel)

                Circle()
                    .trim(from: 0, to: 0.65)
                    .stroke(Color.openClawRed.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: recordButtonSize + 10, height: recordButtonSize + 10)
                    .rotationEffect(.degrees(recordingRingAngle))
                    .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: recordingRingAngle)
            }

            Circle()
                .fill(buttonColor)
                .frame(width: recordButtonSize, height: recordButtonSize)
                .shadow(color: buttonColor.opacity(0.4), radius: isPressed ? 4 : 8, y: isPressed ? 1 : 3)
                .scaleEffect(isPressed ? 0.9 : 1.0)

            buttonIcon
                .font(.system(.title, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: recordButtonSize + 60, height: recordButtonSize + 60)
        .contentShape(Circle())
        .gesture(recordGesture)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPressed)
        .disabled(viewModel.state == .transcribing || viewModel.state == .organizing)
        .accessibilityLabel(accessibilityLabel)
    }

    private var recordingRingAngle: Double {
        viewModel.state == .recording ? 360 : 0
    }

    private var buttonColor: Color {
        switch viewModel.state {
        case .idle: return .openClawRed
        case .recording: return .red
        case .transcribing, .organizing: return .openClawRed.opacity(0.5)
        }
    }

    @ViewBuilder
    private var buttonIcon: some View {
        switch viewModel.state {
        case .idle:
            Image(systemName: "mic.fill")
        case .recording:
            Image(systemName: "mic.fill")
                .symbolEffect(.pulse)
        case .transcribing, .organizing:
            Image(systemName: "waveform")
        }
    }

    private var accessibilityLabel: String {
        switch viewModel.state {
        case .idle: return "按住说话，录完松开自动转写"
        case .recording: return "正在录音，松开结束"
        case .transcribing: return "正在转写"
        case .organizing: return "正在整理纪要"
        }
    }

    private var canInteract: Bool {
        viewModel.state == .idle || viewModel.state == .recording
    }

    // MARK: - 按住说话手势（参考 VoiceDiaryView）

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed, canInteract else { return }
                isPressed = true
                isHolding = false
                if viewModel.state == .recording {
                    return
                }
                if hapticsEnabled {
                    Haptics.impact(.medium)
                }
                holdTimer = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: holdThreshold)
                    guard !Task.isCancelled else { return }
                    isHolding = true
                    if hapticsEnabled {
                        Haptics.impact(.heavy)
                    }
                    viewModel.startRecording()
                }
            }
            .onEnded { _ in
                holdTimer?.cancel()
                holdTimer = nil
                guard isPressed else { return }
                isPressed = false
                if hapticsEnabled {
                    Haptics.impact(.light)
                }
                if viewModel.state == .recording || isHolding {
                    viewModel.stopRecordingAndTranscribe()
                } else {
                    showHoldHint = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        showHoldHint = false
                    }
                }
            }
    }
}