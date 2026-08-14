import SwiftUI
import Observation
import UIKit

// MARK: - 兼容别名（语音输入统一 Core：ClawTalk/Core/VoiceInput）

/// 语音输入模式（短语音/长录音）。
typealias GlobalVoiceInputMode = VoiceInputMode
/// 语音输入状态（空闲/录音中/转写中）。
typealias GlobalVoiceInputState = VoiceInputPhase

// MARK: - ViewModel

/// 全局语音输入 ViewModel（D1 底座）：短语音（按住说话）/ 长录音 / 上滑切长录音 /
/// 转写（STT）统一由 ClawTalk/Core/VoiceInput/VoiceInputStateMachine 承担，
/// 本类保持原公开 API 与行为，供页面与单元测试使用。
@MainActor
@Observable
final class GlobalVoiceInputViewModel {
    let machine: VoiceInputStateMachine

    var mode: GlobalVoiceInputMode {
        get { machine.mode }
        set { machine.mode = newValue }
    }

    var state: GlobalVoiceInputState { machine.phase }
    var audioLevel: Float { machine.audioLevel }
    var durationText: String { machine.durationText }
    var waveformLevels: [Float] { machine.waveformLevels }
    var transcript: String {
        get { machine.transcript }
        set { machine.transcript = newValue }
    }
    var errorMessage: String? { machine.errorMessage }

    /// 识别完成回调（页面承接文本，例如预填目标功能）。
    var onTranscript: ((String, GlobalVoiceInputMode) -> Void)? {
        get { machine.onTranscript }
        set { machine.onTranscript = newValue }
    }

    init(settingsStore: SettingsStore) {
        machine = VoiceInputStateMachine(settingsStore: settingsStore)
    }

#if DEBUG
    /// Test seam: enter the recording state without mic permission/hardware (DEBUG builds only).
    /// Lets unit tests exercise the idle -> recording -> stop/discard state machine.
    func beginRecordingForTesting() {
        machine.beginRecordingForTesting()
    }
#endif

    // MARK: - 短语音（按住说话）

    func startShortRecording() {
        machine.startShort()
    }

    func stopShortRecording() {
        machine.finishShort()
    }

    // MARK: - 短语音 → 长录音切换（按住上滑，N3 悬浮麦）

    func switchToLongMode() {
        machine.switchToLong()
    }

    // MARK: - 长录音（点按开始/结束）

    func startLongRecording() {
        machine.startLong()
    }

    func stopLongRecording() {
        machine.finishLong()
    }

    /// 页面退出时丢弃未完成的录音（不转写、不保存）。
    func discard() {
        machine.discard()
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
                .font(.system(.title1, weight: .medium))
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

// MARK: - 可内嵌录音按钮（非悬浮）

/// 与悬浮麦同能力的可内嵌录音按钮：按住说话 / 上滑切长录音 / 长录音点按结束，
/// 声呐波纹 + 呼吸光晕 + 录音环形动画；非 overlay 悬浮，可嵌入页面内容流。
/// 复用同一个 GlobalVoiceInputViewModel，转写结果经 onTranscript 回调交给页面承接。
struct GlobalVoiceInputEmbedded: View {
    @State private var viewModel: GlobalVoiceInputViewModel
    @State private var isPressed = false
    @State private var didSwitchToLong = false
    @State private var isBreathing = false

    private let buttonSize: CGFloat = 64
    private let swipeUpThreshold: CGFloat = -70

    init(settingsStore: SettingsStore, onTranscript: ((String, GlobalVoiceInputMode) -> Void)? = nil) {
        let vm = GlobalVoiceInputViewModel(settingsStore: settingsStore)
        vm.onTranscript = onTranscript
        _viewModel = State(initialValue: vm)
    }

    var body: some View {
        VStack(spacing: 10) {
            recordButton
            statusLine
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
        .onDisappear {
            viewModel.discard()
        }
    }

    // MARK: - 录音按钮（与悬浮麦同款：声呐 + 呼吸光晕 + 录音环形动画）

    private var recordButton: some View {
        ZStack {
            // 声呐波纹：按住/录音时从按钮中心向外扩散
            if isPressed || viewModel.state == .recording {
                SonarRings(color: buttonColor)
                    .frame(width: buttonSize + 80, height: buttonSize + 80)
            }

            if viewModel.state == .idle {
                // 呼吸光晕：双层错相（与悬浮麦一致）
                Circle()
                    .fill(Color.openClawRed.opacity(0.22))
                    .frame(
                        width: buttonSize + (isBreathing ? 36 : 12),
                        height: buttonSize + (isBreathing ? 36 : 12)
                    )
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: isBreathing)
                Circle()
                    .fill(Color.openClawRed.opacity(0.12))
                    .frame(
                        width: buttonSize + (isBreathing ? 52 : 22),
                        height: buttonSize + (isBreathing ? 52 : 22)
                    )
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: isBreathing)
            }

            if viewModel.state == .recording {
                if viewModel.mode == .long {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(Color.openClawRed.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: buttonSize + 12, height: buttonSize + 12)
                        .rotationEffect(.degrees(recordingRingAngle))
                        .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: recordingRingAngle)
                } else {
                    Circle()
                        .stroke(Color.openClawRed.opacity(0.3), lineWidth: 3)
                        .frame(
                            width: buttonSize + 14 + CGFloat(viewModel.audioLevel * 52),
                            height: buttonSize + 14 + CGFloat(viewModel.audioLevel * 52)
                        )
                        .animation(.easeOut(duration: 0.08), value: viewModel.audioLevel)
                }
            }

            // 按钮主体：按压缩强 + 点亮高光
            Circle()
                .fill(buttonColor)
                .frame(width: buttonSize, height: buttonSize)
                .shadow(color: buttonColor.opacity(isPressed ? 0.75 : 0.45), radius: isPressed ? 8 : 10, y: isPressed ? 2 : 6)
                .scaleEffect(isPressed ? 0.85 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: isPressed)
                .overlay(
                    Circle()
                        .fill(.white.opacity(isPressed ? 0.26 : 0.10))
                        .scaleEffect(isPressed ? 0.92 : 1.0)
                        .animation(.easeOut(duration: 0.18), value: isPressed)
                )

            buttonIcon
                .font(.system(.title1, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: buttonSize + 80, height: buttonSize + 80)
        .contentShape(Circle())
        .gesture(recordGesture)
        .disabled(viewModel.state == .transcribing)
        .accessibilityLabel(accessibilityLabel)
    }

    private var recordingRingAngle: Double {
        viewModel.state == .recording ? 360 : 0
    }

    private var buttonColor: Color {
        switch viewModel.state {
        case .idle: return .openClawRed
        case .recording: return viewModel.mode == .long ? AppTokens.voiceRecordingRed : .red
        case .transcribing: return .openClawRed.opacity(0.5)
        }
    }

    @ViewBuilder
    private var buttonIcon: some View {
        switch viewModel.state {
        case .idle:
            Image(systemName: "mic.fill")
        case .recording:
            ZStack {
                Image(systemName: viewModel.mode == .long ? "stop.fill" : "waveform")
                    .symbolEffect(.pulse)
                if viewModel.mode == .short {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                        .offset(x: 11, y: -11)
                }
            }
        case .transcribing:
            Image(systemName: "waveform")
        }
    }

    private var accessibilityLabel: String {
        switch viewModel.state {
        case .idle: return "按住说话，上滑切长录音"
        case .recording: return viewModel.mode == .long ? "长录音中，点按结束" : "正在录音，松开结束"
        case .transcribing: return "正在转写"
        }
    }

    // MARK: - 手势（按住说话 / 上滑切长录音 / 长录音点按结束）

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch viewModel.state {
                case .idle:
                    guard viewModel.mode == .short, !isPressed else { return }
                    isPressed = true
                    Haptics.impact(.medium)
                    viewModel.startShortRecording()
                case .recording:
                    if viewModel.mode == .short,
                       value.translation.height < swipeUpThreshold,
                       !didSwitchToLong {
                        didSwitchToLong = true
                        Haptics.success()
                        viewModel.switchToLongMode()
                    }
                case .transcribing:
                    break
                }
            }
            .onEnded { _ in
                isPressed = false
                if didSwitchToLong {
                    didSwitchToLong = false
                    return
                }
                switch viewModel.mode {
                case .short:
                    if viewModel.state == .recording {
                        viewModel.stopShortRecording()
                    }
                case .long:
                    if viewModel.state == .recording {
                        viewModel.stopLongRecording()
                    }
                }
            }
    }

    // MARK: - 状态提示（内嵌紧凑样式）

    @ViewBuilder
    private var statusLine: some View {
        VStack(spacing: 6) {
            switch viewModel.state {
            case .idle:
                Text(viewModel.mode.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .recording:
                Text(viewModel.mode == .long
                     ? "长录音中 · \(viewModel.durationText)（点按结束）"
                     : "正在录音… 松开结束")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.openClawRed)
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("转写中…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - 悬浮圆麦组件（N3）

/// 主页小卡页面统一的悬浮麦克风：屏幕下方偏上、居中悬浮，不挡内容滚动。
/// - 按住 = 短语音（最长 60 秒），松开识别；
/// - 按住后上滑 = 切换到长录音（最长 60 分钟），松开继续录（锁定），点按结束；
/// - 空闲呼吸 / 录音波纹 / 触觉反馈 / 手指上方波形提示。
struct GlobalVoiceInputFloating: View {
    @State private var viewModel: GlobalVoiceInputViewModel
    @State private var isPressed = false
    @State private var didSwitchToLong = false
    @State private var isBreathing = false

    private let buttonSize: CGFloat = 64
    private let swipeUpThreshold: CGFloat = -70

    init(settingsStore: SettingsStore, onTranscript: ((String, GlobalVoiceInputMode) -> Void)? = nil) {
        let vm = GlobalVoiceInputViewModel(settingsStore: settingsStore)
        vm.onTranscript = onTranscript
        _viewModel = State(initialValue: vm)
    }

    var body: some View {
        VStack(spacing: 16) {
            statusPanel
            recordButton
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
        .onDisappear {
            viewModel.discard()
        }
    }

    // MARK: - 录音按钮

    private var recordButton: some View {
        ZStack {
            // 声呐波纹：按住/录音时从按钮中心向外扩散
            if isPressed || viewModel.state == .recording {
                SonarRings(color: buttonColor)
                    .frame(width: buttonSize + 80, height: buttonSize + 80)
            }

            if viewModel.state == .idle {
                // 呼吸光晕：双层错相，幅度加大（待机更有「活」感）
                Circle()
                    .fill(Color.openClawRed.opacity(0.22))
                    .frame(
                        width: buttonSize + (isBreathing ? 36 : 12),
                        height: buttonSize + (isBreathing ? 36 : 12)
                    )
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: isBreathing)
                Circle()
                    .fill(Color.openClawRed.opacity(0.12))
                    .frame(
                        width: buttonSize + (isBreathing ? 52 : 22),
                        height: buttonSize + (isBreathing ? 52 : 22)
                    )
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: isBreathing)
            }

            if viewModel.state == .recording {
                if viewModel.mode == .long {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(Color.openClawRed.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: buttonSize + 12, height: buttonSize + 12)
                        .rotationEffect(.degrees(recordingRingAngle))
                        .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: recordingRingAngle)
                } else {
                    Circle()
                        .stroke(Color.openClawRed.opacity(0.3), lineWidth: 3)
                        .frame(
                            width: buttonSize + 14 + CGFloat(viewModel.audioLevel * 52),
                            height: buttonSize + 14 + CGFloat(viewModel.audioLevel * 52)
                        )
                        .animation(.easeOut(duration: 0.08), value: viewModel.audioLevel)
                }
            }

            // 按钮主体：按压缩强（0.85）+ 点亮高光
            Circle()
                .fill(buttonColor)
                .frame(width: buttonSize, height: buttonSize)
                .shadow(color: buttonColor.opacity(isPressed ? 0.75 : 0.45), radius: isPressed ? 8 : 10, y: isPressed ? 2 : 6)
                .scaleEffect(isPressed ? 0.85 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: isPressed)
                .overlay(
                    Circle()
                        .fill(.white.opacity(isPressed ? 0.26 : 0.10))
                        .scaleEffect(isPressed ? 0.92 : 1.0)
                        .animation(.easeOut(duration: 0.18), value: isPressed)
                )

            buttonIcon
                .font(.system(.title1, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: buttonSize + 80, height: buttonSize + 80)
        .contentShape(Circle())
        .gesture(recordGesture)
        .disabled(viewModel.state == .transcribing)
        .accessibilityLabel(accessibilityLabel)
    }
    private var recordingRingAngle: Double {
        viewModel.state == .recording ? 360 : 0
    }

    private var buttonColor: Color {
        switch viewModel.state {
        case .idle: return .openClawRed
        case .recording: return viewModel.mode == .long ? AppTokens.voiceRecordingRed : .red
        case .transcribing: return .openClawRed.opacity(0.5)
        }
    }

    @ViewBuilder
    private var buttonIcon: some View {
        switch viewModel.state {
        case .idle:
            Image(systemName: "mic.fill")
        case .recording:
            ZStack {
                Image(systemName: viewModel.mode == .long ? "stop.fill" : "waveform")
                    .symbolEffect(.pulse)
                if viewModel.mode == .short {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                        .offset(x: 11, y: -11)
                }
            }
        case .transcribing:
            Image(systemName: "waveform")
        }
    }
    private var accessibilityLabel: String {
        switch viewModel.state {
        case .idle: return "按住说话，上滑切长录音"
        case .recording: return viewModel.mode == .long ? "长录音中，点按结束" : "正在录音，松开结束"
        case .transcribing: return "正在转写"
        }
    }

    // MARK: - 手势（按住说话 / 上滑切长录音 / 长录音点按结束）

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch viewModel.state {
                case .idle:
                    guard viewModel.mode == .short, !isPressed else { return }
                    isPressed = true
                    Haptics.impact(.medium)
                    // 按下立即开始录音：界面马上有「接收语音」的反应；
                    // 松开时不足 0.5 秒的短按由 stopShortRecording 自动判误触丢弃。
                    viewModel.startShortRecording()
                case .recording:
                    if viewModel.mode == .short,
                       value.translation.height < swipeUpThreshold,
                       !didSwitchToLong {
                        didSwitchToLong = true
                        Haptics.success()
                        viewModel.switchToLongMode()
                    }
                case .transcribing:
                    break
                }
            }
            .onEnded { _ in
                isPressed = false
                // 已上滑切长录音：松开不停止（锁定继续录），点按才结束
                if didSwitchToLong {
                    didSwitchToLong = false
                    return
                }
                switch viewModel.mode {
                case .short:
                    if viewModel.state == .recording {
                        viewModel.stopShortRecording()
                    }
                case .long:
                    if viewModel.state == .recording {
                        viewModel.stopLongRecording()
                    }
                }
            }
    }

    // MARK: - 手指上方状态区（不遮挡按钮）

    @ViewBuilder
    private var statusPanel: some View {
        VStack(spacing: 8) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.55)))
            }

            if !viewModel.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("识别结果")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Button("清空") {
                            viewModel.transcript = ""
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                    }
                    Text(viewModel.transcript)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .padding(10)
                .frame(maxWidth: 280)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.black.opacity(0.6))
                )
            }

            stateIndicator
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch viewModel.state {
        case .idle:
            Text("按住说话 · 上滑切长录音")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.55)))
        case .recording:
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.mode == .long
                         ? "长录音中 · \(viewModel.durationText)（点按结束）"
                         : "正在录音… 松开结束")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                miniWaveform
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.black.opacity(0.6))
            )
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("转写中…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.black.opacity(0.6))
            )
        }
    }

    /// 迷你频谱条：随真实录音电平起伏（手指上方可见，不被手指遮挡）。
    /// 迷你频谱条：随真实录音电平起伏（手指上方可见，不被手指遮挡）。
    /// 出现时从中心横向展开（scale + opacity 过渡）。
    private var miniWaveform: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 3, height: barHeight(index: index))
            }
        }
        .frame(height: 22)
        .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.42, dampingFraction: 0.7), value: viewModel.state)
        .animation(.easeOut(duration: 0.1), value: viewModel.audioLevel)
    }
    private func barHeight(index: Int) -> CGFloat {
        let seeds: [CGFloat] = [0.5, 1.0, 0.7, 1.2, 0.8, 1.1, 0.6]
        let seed = seeds[index % seeds.count]
        let level = max(0.06, CGFloat(viewModel.audioLevel) * 18)
        let wave = CGFloat(sin(Date().timeIntervalSince1970 * 6 + Double(index) * 0.9))
        return max(4, min(20, level * seed + wave * 2 + 3))
    }
}

/// 声呐波纹：按住/录音时从按钮中心向外扩散的圆环（Canvas 30fps，轻量）。
private struct SonarRings: View {
    let color: Color
    private let ringCount = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in 0..<ringCount {
                    let progress = (t * 0.55 + Double(i) / Double(ringCount)).truncatingRemainder(dividingBy: 1.0)
                    let radius = size.width * (0.12 + 0.36 * progress)
                    let alpha = (1.0 - progress) * 0.5
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(alpha)), lineWidth: 1.8)
                }
            }
        }
        .allowsHitTesting(false)
    }
}