import SwiftUI

/// 语音日记页：按日期分组的日记列表 + 底部按住说话录音按钮。
/// - 按住底部按钮说话，松开后自动转写并分类（待办/灵感/日记）
/// - 录音中显示外圈脉冲 + 转圈动画；转写期间显示「整理中…」
/// - 无日记时显示诚实空状态（不塞假数据）
/// - 联动：待办自动加入提醒列表（成功显示「已加入提醒」小标）；灵感自动沉淀记忆中心（成功显示「已存入记忆」小标）
struct VoiceDiaryView: View {
    @State private var viewModel: VoiceDiaryViewModel
    /// 关闭/返回回调（由入口通过 sheet / NavigationStack 传入）
    var onBack: (() -> Void)?

    // 按住说话手势状态（参考 TalkButton / InlineMicButton 的模型）
    @State private var isPressed = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var isHolding = false
    @State private var showHoldHint = false

    private let hapticsEnabled: Bool
    private let recordButtonSize: CGFloat = 72
    /// 按住多久算开始录音（0.3 秒，与 TalkButton 一致）
    private let holdThreshold: UInt64 = 300_000_000

    init(
        settingsStore: SettingsStore,
        careReminderStore: CareReminderStore? = nil,
        memoryProfileStore: MemoryProfileStore? = nil,
        onBack: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: VoiceDiaryViewModel(
            settingsStore: settingsStore,
            careReminderStore: careReminderStore,
            memoryProfileStore: memoryProfileStore
        ))
        self.onBack = onBack
        self.hapticsEnabled = settingsStore.settings.hapticsEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider().opacity(0.3)
            Group {
                if viewModel.entries.isEmpty {
                    emptyState
                } else {
                    entryList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.3)
            recordArea
        }
        .background(Color(.systemBackground))
        .onDisappear { viewModel.discardActiveRecording() }
    }

    // MARK: - 导航栏

    private var navBar: some View {
        ZStack {
            Text("语音日记")
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

    // MARK: - 列表（按日期分组）

    private var entryList: some View {
        let grouped = Dictionary(grouping: viewModel.entries) {
            Calendar.current.startOfDay(for: $0.date)
        }
        let dayKeys = grouped.keys.sorted(by: >)

        return List {
            if let notice = viewModel.linkageNotice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(dayKeys, id: \.self) { day in
                let dayEntries = (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt }
                Section(header: Text(Self.dayHeader(for: day))) {
                    ForEach(dayEntries) { entry in
                        DiaryEntryRow(entry: entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 日期分组标题：今天 / 昨天 / 明天 / M月d日 星期X
    private static func dayHeader(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        if calendar.isDateInTomorrow(day) { return "明天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: day)
    }

    // MARK: - 空状态（诚实，不塞假数据）

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("还没有日记")
                .font(.headline)
            Text("按住底部麦克风说一句话，松开后会自动整理成日记、待办或灵感。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
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
            Text(showHoldHint ? "按住说话，松开结束" : "按住说话，松开自动整理")
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

    // MARK: - 按住说话按钮

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
        case .idle: return "按住说话，松开自动整理成日记"
        case .recording: return "正在录音，松开结束"
        case .transcribing: return "正在整理转写结果"
        }
    }

    private var canInteract: Bool {
        viewModel.state == .idle || viewModel.state == .recording
    }

    // MARK: - 按住说话手势（参考 TalkButton / InlineMicButton）

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
                    viewModel.stopRecordingAndProcess()
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

/// 日记列表行：类别徽章 + 时间 + 正文。
private struct DiaryEntryRow: View {
    let entry: DiaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DiaryCategoryBadge(category: entry.category)
                if entry.linkedReminderID != nil {
                    Label("已加入提醒", systemImage: "bell.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
                if entry.linkedToMemory == true {
                    Label("已存入记忆", systemImage: "brain.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.purple)
                }
                Spacer()
                Text(timeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: entry.createdAt)
    }
}
