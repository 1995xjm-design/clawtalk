import SwiftUI

/// 随手捕捉页：顶部归档反馈横幅 + 识别结果 + 手动改去向 + 文本框 + 底部按住说话按钮。
///
/// 交互流：
/// - 按住说话 / 输入文字 → 转写 → 自动判断去向并归档 → 顶部绿色横幅「已归档到 XX」；
/// - 手动改去向（四选一：日记/记忆/待办/记账）→ 追加归档一条到所选位置；
/// - 归档失败 → 顶部橙色横幅提示原因，不静默。
struct CaptureView: View {
    @State private var viewModel: CaptureViewModel
    /// 关闭/返回回调（由入口通过 sheet / NavigationStack 传入）
    var onBack: (() -> Void)?

    // 按住说话手势状态（参考 VoiceDiaryView / TalkButton / InlineMicButton 的模型）
    @State private var isPressed = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var isHolding = false
    @State private var showHoldHint = false
    @State private var transcriptText = ""
    /// 手动改去向（四选一，默认日记；仅在选择变化时触发归档）
    @State private var manualDestination: CaptureDestination = .diary

    private let hapticsEnabled: Bool
    private let recordButtonSize: CGFloat = 72
    /// 按住多久算开始录音（0.3 秒，与 VoiceDiaryView 一致）
    private let holdThreshold: UInt64 = 300_000_000

    init(
        settingsStore: SettingsStore,
        careReminderStore: CareReminderStore? = nil,
        memoryProfileStore: MemoryProfileStore? = nil,
        expenseStore: ExpenseStore? = nil,
        onBack: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: CaptureViewModel(
            settingsStore: settingsStore,
            careReminderStore: careReminderStore,
            memoryProfileStore: memoryProfileStore,
            expenseStore: expenseStore
        ))
        self.onBack = onBack
        self.hapticsEnabled = settingsStore.settings.hapticsEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    feedbackBanner
                    resultSection
                    destinationPickerSection
                    textInputSection
                }
                .padding(16)
            }
            Divider().opacity(0.3)
            recordArea
        }
        .background(Color(.systemBackground))
        .onDisappear { viewModel.discardActiveRecording() }
    }

    // MARK: - 导航栏

    private var navBar: some View {
        ZStack {
            Text("随手捕捉")
                .font(.headline)
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Color(.systemGray5), in: Circle())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 52)
    }

    // MARK: - 归档反馈横幅（成功绿色 / 失败橙色，页面顶部，不静默）

    @ViewBuilder
    private var feedbackBanner: some View {
        if let feedback = viewModel.feedback {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: feedback.tone == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))

                VStack(alignment: .leading, spacing: 2) {
                    Text(feedback.title)
                        .font(.subheadline.weight(.semibold))
                    if let detail = feedback.detail {
                        Text(detail)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(feedback.tone == .success ? Color.green : Color.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill((feedback.tone == .success ? Color.green : Color.orange).opacity(0.12))
            )
        }
    }

    // MARK: - 识别结果 + 自动归档去向

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别结果")
                .font(.headline)

            if viewModel.transcript.isEmpty {
                Text("按住下方按钮说一句，或直接在文本框输入。识别后会自动归档到对应位置。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(viewModel.transcript)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if let detected = viewModel.detectedDestination {
                    Label("自动归档去向：\(detected.rawValue)", systemImage: detected.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - 手动改去向（四选一）

    private var destinationPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动改去向")
                .font(.headline)
            Text("选择后会追加归档一条到所选位置，原自动归档保留。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("归档去向", selection: $manualDestination) {
                ForEach(CaptureDestination.manualChoices) { destination in
                    Label(destination.rawValue, systemImage: destination.systemImage)
                        .tag(destination)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: manualDestination) { _, newValue in
                guard !viewModel.transcript.isEmpty else { return }
                viewModel.archiveManually(to: newValue)
            }
        }
    }

    // MARK: - 文本框输入

    private var textInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("输入一句话，自动归档", text: $transcriptText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)

                Button(action: submitText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .disabled(viewModel.state == .transcribing)
                .accessibilityLabel("归档输入的文字")
            }

            Text("支持：提醒（提醒我/记得）、灵感、金额（XX元/块）、日记")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func submitText() {
        let text = transcriptText
        transcriptText = ""
        viewModel.submitText(text)
    }

    // MARK: - 底部录音区

    private var recordArea: some View {
        VStack(spacing: 12) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            recordButton

            statusLabel
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.state {
        case .idle:
            Text(showHoldHint ? "按住说话，松开结束" : "按住说话，松开自动归档")
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
                Text("整理中…")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 按住说话按钮（参考 VoiceDiaryView 同款手势）

    private var recordButton: some View {
        ZStack {
            // 录音中：外圈随电平脉冲 + 转圈动画
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

            // 转写中：转圈进度
            if viewModel.state == .transcribing {
                Circle()
                    .trim(from: 0, to: 0.65)
                    .stroke(Color.openClawRed.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: recordButtonSize + 10, height: recordButtonSize + 10)
                    .rotationEffect(.degrees(transcribingRingAngle))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: transcribingRingAngle)
            }

            // 主按钮
            Circle()
                .fill(buttonColor)
                .frame(width: recordButtonSize, height: recordButtonSize)
                .shadow(color: buttonColor.opacity(0.4), radius: isPressed ? 4 : 8, y: isPressed ? 1 : 3)
                .scaleEffect(isPressed ? 0.9 : 1.0)

            // 图标
            buttonIcon
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: recordButtonSize + 60, height: recordButtonSize + 60)
        .contentShape(Circle())
        .gesture(recordGesture)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPressed)
        .disabled(viewModel.state == .transcribing)
        .accessibilityLabel(accessibilityLabel)
    }

    /// 录音中的转圈角度：进入录音状态时从 0 转到 360 并无限重复
    private var recordingRingAngle: Double {
        viewModel.state == .recording ? 360 : 0
    }

    /// 转写中的转圈角度
    private var transcribingRingAngle: Double {
        viewModel.state == .transcribing ? 360 : 0
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
            Image(systemName: "mic.fill")
        case .recording:
            Image(systemName: "mic.fill")
                .symbolEffect(.pulse)
        case .transcribing:
            Image(systemName: "waveform")
        }
    }

    private var accessibilityLabel: String {
        switch viewModel.state {
        case .idle: return "按住说话，松开自动归档"
        case .recording: return "正在录音，松开结束"
        case .transcribing: return "正在整理转写结果"
        }
    }

    private var canInteract: Bool {
        viewModel.state == .idle || viewModel.state == .recording
    }

    // MARK: - 按住说话手势（参考 VoiceDiaryView 同款）

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed, canInteract else { return }
                isPressed = true
                isHolding = false
                if viewModel.state == .recording {
                    // 录音中再次按下：仅标记按压，松开即停止
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
                    viewModel.startRecording()
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
                if viewModel.state == .recording || isHolding {
                    viewModel.stopRecordingAndCapture()
                } else {
                    // 短按未开始录音：提示按住说话
                    showHoldHint = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        showHoldHint = false
                    }
                }
            }
    }
}
