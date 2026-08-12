import SwiftUI
import UIKit

/// 知识库问答页录音状态。
enum KBVoiceState: Equatable {
    case idle
    case recording
    case transcribing
}

/// 语音提问（按住说话）：复用 AudioCaptureManager + STT，与文档口述/会议纪要同链路。
@Observable
@MainActor
final class KBVoiceRecorder {
    private(set) var state: KBVoiceState = .idle
    var audioLevel: Float = 0
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "知识库问答", errorMessage)
            }
        }
    }

    private let audioCapture = AudioCaptureManager()
    private let settingsStore: SettingsStore
    private var transcriptionService: (any TranscriptionService)?
    private var levelTimer: Timer?
    private var recordingStart: Date?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    // MARK: - 录音

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
            restoreWakeListening()
        }
    }

    /// 松开录音：结束录音并转写；返回有效文字，无内容时返回 nil（errorMessage 已设置）。
    func stopRecordingAndTranscribe() async -> String? {
        guard state == .recording else { return nil }
        stopLevelTimer()
        let samples = audioCapture.stopRecording()

        // 与聊天页同阈值：<0.5s 或样本过少视为误触。
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        guard duration >= 0.5, samples.count > 8000 else {
            state = .idle
            restoreWakeListening()
            return nil
        }

        state = .transcribing
        defer { restoreWakeListening() }

        guard let stt = makeTranscriptionService() else {
            errorMessage = "语音输入已在设置中关闭，请到设置页开启后重试"
            state = .idle
            return nil
        }
        do {
            let text = try await stt.transcribe(audioSamples: samples)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            state = .idle
            guard !trimmed.isEmpty else {
                errorMessage = "没有识别到内容，请再试一次"
                return nil
            }
            return trimmed
        } catch {
            errorMessage = "转写失败：\(AppErrorText.localized(error.localizedDescription))"
            state = .idle
            return nil
        }
    }

    /// 页面退出时丢弃未完成录音（不转写、不保存）。
    func discardActiveRecording() {
        guard state == .recording else { return }
        stopLevelTimer()
        _ = audioCapture.stopRecording()
        state = .idle
        restoreWakeListening()
    }

    // MARK: - STT 服务工厂（与文档口述/会议纪要同规则）

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

    private func restoreWakeListening() {
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }
}

/// 知识库问答页：顶部语音提问（按住说话）+ 文字输入 + 历史问答列表（问题/答案/来源）。
struct KBView: View {
    @State private var store: KBStore
    @State private var voiceRecorder: KBVoiceRecorder
    @State private var query = ""

    // 按住说话手势状态（参考文档口述/语音日记）。
    @State private var isPressed = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var isHolding = false
    @State private var showHoldHint = false

    private let hapticsEnabled: Bool
    private let recordButtonSize: CGFloat = 56
    /// 按住多久算开始录音（0.3 秒，与文档口述/语音日记一致）。
    private let holdThreshold: UInt64 = 300_000_000

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil, agentId: String? = nil) {
        _store = State(initialValue: KBStore(settings: settings, agentId: agentId))
        _voiceRecorder = State(initialValue: KBVoiceRecorder(settingsStore: settings))
        self.hapticsEnabled = settings.settings.hapticsEnabled
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inputSection
                statusSection
                historySection
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("知识库问答")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            holdTimer?.cancel()
            voiceRecorder.discardActiveRecording()
        }
    }

    // MARK: - 提问区：文字输入 + 发送 + 按住说话

    private var inputSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("输入问题…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { askFromText() }

                Button {
                    askFromText()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(canSend ? Color.openClawRed : Color.gray.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }

            HStack(spacing: 12) {
                recordButton
                voiceStatusLabel
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var canSend: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !store.isAsking
    }

    private func askFromText() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        query = ""
        Task { _ = await store.ask(trimmed) }
    }

    private func askFromVoice() {
        Task {
            if let text = await voiceRecorder.stopRecordingAndTranscribe() {
                query = ""
                _ = await store.ask(text)
            }
        }
    }

    // MARK: - 状态区

    @ViewBuilder
    private var statusSection: some View {
        VStack(spacing: 8) {
            if store.isAsking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在从记忆库检索…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            if let error = store.lastError {
                errorBanner(error)
            }
            if let error = voiceRecorder.errorMessage {
                errorBanner(error)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
            Text(message)
                .font(.caption)
                .lineLimit(2)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 历史问答列表

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("问答记录")
                    .font(.headline)
                Spacer()
                if !store.questions.isEmpty {
                    Button("清空") { store.clearHistory() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if store.questions.isEmpty {
                ContentUnavailableView(
                    "还没有问答记录",
                    systemImage: "text.book.closed",
                    description: Text("用文字或语音提问，答案会基于记忆库检索并标注来源。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ForEach(store.questions.reversed()) { entry in
                    KBQuestionRow(entry: entry)
                }
            }
        }
    }

    // MARK: - 按住说话按钮

    private var recordButton: some View {
        ZStack {
            if voiceRecorder.state == .recording {
                Circle()
                    .stroke(Color.openClawRed.opacity(0.25), lineWidth: 3)
                    .frame(
                        width: recordButtonSize + 14 + CGFloat(voiceRecorder.audioLevel * 50),
                        height: recordButtonSize + 14 + CGFloat(voiceRecorder.audioLevel * 50)
                    )
                    .animation(.easeOut(duration: 0.08), value: voiceRecorder.audioLevel)
            }

            Circle()
                .fill(recordButtonColor)
                .frame(width: recordButtonSize, height: recordButtonSize)
                .shadow(color: recordButtonColor.opacity(0.4), radius: isPressed ? 4 : 8, y: isPressed ? 1 : 3)
                .scaleEffect(isPressed ? 0.9 : 1.0)

            recordButtonIcon
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: recordButtonSize + 30, height: recordButtonSize + 30)
        .contentShape(Circle())
        .gesture(recordGesture)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPressed)
        .disabled(store.isAsking || voiceRecorder.state == .transcribing)
        .accessibilityLabel(accessibilityLabel)
    }

    private var recordButtonColor: Color {
        switch voiceRecorder.state {
        case .idle: return .openClawRed
        case .recording: return .red
        case .transcribing: return .openClawRed.opacity(0.5)
        }
    }

    @ViewBuilder
    private var recordButtonIcon: some View {
        switch voiceRecorder.state {
        case .idle:
            Image(systemName: "mic.fill")
        case .recording:
            Image(systemName: "mic.fill")
                .symbolEffect(.pulse)
        case .transcribing:
            Image(systemName: "waveform")
        }
    }

    private var accessibilityLabel: String {
        switch voiceRecorder.state {
        case .idle: return "按住说话提问"
        case .recording: return "正在录音，松开结束"
        case .transcribing: return "正在转写"
        }
    }

    private var canInteract: Bool {
        !store.isAsking && (voiceRecorder.state == .idle || voiceRecorder.state == .recording)
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed, canInteract else { return }
                isPressed = true
                isHolding = false
                if voiceRecorder.state == .recording {
                    return
                }
                if hapticsEnabled {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                holdTimer = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: holdThreshold)
                    guard !Task.isCancelled else { return }
                    isHolding = true
                    if hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    }
                    voiceRecorder.startRecording()
                }
            }
            .onEnded { _ in
                holdTimer?.cancel()
                holdTimer = nil
                guard isPressed else { return }
                isPressed = false
                if hapticsEnabled {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                if voiceRecorder.state == .recording || isHolding {
                    askFromVoice()
                } else {
                    showHoldHint = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        showHoldHint = false
                    }
                }
            }
    }

    @ViewBuilder
    private var voiceStatusLabel: some View {
        switch voiceRecorder.state {
        case .idle:
            Text(showHoldHint ? "按住说话，松开提问" : "按住说话，语音提问")
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
        }
    }
}

// MARK: - 单条问答记录

private struct KBQuestionRow: View {
    let entry: KBQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(entry.question)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(entry.kind.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(badgeColor.opacity(0.12)))
            }

            Text(entry.answer)
                .font(.callout)
                .foregroundStyle(entry.kind == .error ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !entry.sources.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("来自记忆库", systemImage: "books.vertical.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.teal)
                    ForEach(entry.sources, id: \.self) { path in
                        Text("· \(path)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else if entry.kind == .noResult {
                Text("无来源：记忆库中没有命中内容")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if entry.kind == .error {
                Text("无来源：本次检索未完成")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(Self.timeText(entry.askedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var badgeColor: Color {
        switch entry.kind {
        case .memory: return .teal
        case .agent: return .purple
        case .noResult: return .gray
        case .error: return .red
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
