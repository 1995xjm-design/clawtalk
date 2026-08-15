import SwiftUI
import UIKit

/// 微信式输入栏：左侧麦克风/键盘切换 → 中间输入框或「按住 说话」→ 右侧发送箭头/加号。
///
/// 语音模式「按住 说话」（微信弧形选择层）：
/// - 按住 0.3s 开始录音（onHoldStart），按钮变红「松开 结束」
/// - 上滑 50pt 弹出弧形选择层：中间「松开 发送」，两侧弧线展开
/// - 手指左右滑动按「角度 + 距离」命中侧弧（左「取消」红 / 右「滑到这里转文字」绿），
///   命中高亮 + 弹性放大（spring 吸附）；回中间回落取消高亮
/// - 松手：落在取消 → onHoldCancel；落在转文字 → onHoldTranscribe；未上滑/中间 → onHoldSendVoice
/// - 触感反馈：录音触发/进入选择区/滑入侧弧均有震动
struct WeChatInputBar: View {
    @Binding var text: String
    var voiceInputEnabled: Bool
    var hapticsEnabled: Bool
    var isSending: Bool
    var audioLevel: Float = 0
    var isConversationMode: Bool
    var onToggleVoiceMode: () -> Void
    var onSendText: () -> Void
    var onHoldStart: () -> Void
    var onHoldCancel: () -> Void
    var onHoldSendVoice: () -> Void
    var onHoldTranscribe: () -> Void
    var onAddAttachment: () -> Void

    @State private var isVoiceMode = false
    @State private var isRecording = false
    @State private var showActionLayer = false
    @State private var selectedAction: HoldAction?
    @State private var pressStart: Date?
    @State private var recordingStart: Date?
    @State private var longPressTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool

    /// 长按录音触发时长（秒）：0.15s 轻触即响（原 0.3s 偏钝）
    private let holdToRecordDuration: TimeInterval = 0.15

    /// 弧形选择手势动作（统一手势判定：ClawTalk/Core/VoiceInput/VoiceInputGesture）
    private typealias HoldAction = VoiceInputGestureAction

    var body: some View {
        HStack(spacing: 10) {
            // 左侧：麦克风/键盘切换
            Button(action: toggleVoiceMode) {
                Image(systemName: isVoiceMode ? "keyboard" : "mic.fill")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(.openClawRed)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(.systemGray5)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVoiceMode ? "切换键盘输入" : "切换语音输入")

            if isVoiceMode {
                holdToTalkButton
            } else {
                keyboardField
            }

            // 发送箭头（键盘模式有文字时显示）
            if !isVoiceMode, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: onSendText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(.openClawRed)
                }
                .disabled(isSending)
                .accessibilityLabel("发送")
            }

            // 右侧：加号（语音/键盘模式都在，随时可发图）
            Button(action: onAddAttachment) {
                Image(systemName: "plus.circle.fill")
                    .font(.title)
                    .foregroundStyle(.openClawRed)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("添加附件")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if isVoiceMode && isRecording {
                voiceRecordingOverlay
                    .offset(y: -96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var keyboardField: some View {
        TextField("消息…", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($isInputFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .disabled(isConversationMode)
            .opacity(isConversationMode ? 0.5 : 1.0)
    }

    private var holdToTalkButton: some View {
        Text(isRecording ? "松开 结束" : "按住 说话")
            .font(.callout.weight(.medium))
            .foregroundStyle(isRecording ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isRecording ? Color.red : Color(.systemGray5))
            )
            .contentShape(Rectangle())
            .gesture(holdGesture)
            .animation(.easeInOut(duration: 0.15), value: isRecording)
            .accessibilityLabel(isRecording ? "停止录音" : "按住说话")
            .accessibilityHint("按住开始录音，松开发送；上滑选择取消或转文字")
    }

    /// 按住录音 + 上滑弧形选择（取消/转文字），松手按落点触发。
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStart == nil {
                    pressStart = Date()
                    scheduleRecordingStart()
                }

                guard isRecording else { return }

                if VoiceInputGestureEvaluator.didSlideUpToArc(value.translation) {
                    if !showActionLayer {
                        // 进入选择区：中震动反馈 + 从中心弹簧展开弧形层
                        if hapticsEnabled {
                            Haptics.impact(.medium)
                        }
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            showActionLayer = true
                        }
                    }
                    updateArcSelection(for: value.translation)
                } else if showActionLayer {
                    // 滑回中间：回落（取消高亮）
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                        showActionLayer = false
                        selectedAction = nil
                    }
                }
            }
            .onEnded { value in
                longPressTask?.cancel()
                longPressTask = nil
                pressStart = nil

                if isRecording {
                    isRecording = false
                    if hapticsEnabled {
                        Haptics.impact(.light)
                    }
                    if showActionLayer, VoiceInputGestureEvaluator.didSlideUpToArc(value.translation) {
                        switch selectedAction {
                        case .cancel:
                            onHoldCancel()
                        case .transcribe:
                            onHoldTranscribe()
                        case .send, nil:
                            onHoldSendVoice()
                        }
                    } else {
                        onHoldSendVoice()
                    }
                }

                withAnimation(.easeOut(duration: 0.2)) {
                    showActionLayer = false
                    selectedAction = nil
                    recordingStart = nil
                }
            }
    }

    /// 长按 0.3s 触发录音（快速松手不录音）。
    private func scheduleRecordingStart() {
        longPressTask?.cancel()
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(holdToRecordDuration))
            guard !Task.isCancelled, pressStart != nil, !isRecording else { return }
            beginRecording()
        }
        longPressTask = task
    }

    private func beginRecording() {
        isRecording = true
        recordingStart = Date()
        if hapticsEnabled {
            Haptics.impact(.medium)
        }
        onHoldStart()
    }

    /// 按「角度 + 距离」命中左右弧形按钮（统一几何：VoiceInputGestureEvaluator.arcAction）：
    /// 0° = 正上方（中间「松开 发送」），负角度 = 左弧（取消），正角度 = 右弧（转文字）。
    private func updateArcSelection(for translation: CGSize) {
        setArcSelection(VoiceInputGestureEvaluator.arcAction(for: translation))
    }

    /// 更新弧形高亮：变化时轻震动；滑入侧弧时吸附震动。
    private func setArcSelection(_ newAction: HoldAction?) {
        guard newAction != selectedAction else { return }
        let wasSelected = selectedAction != nil
        selectedAction = newAction
        guard hapticsEnabled else { return }
        Haptics.impact(.light)
        if newAction != nil, !wasSelected {
            Haptics.selection()
        }
    }

    /// 录音浮层：上方语音波形，下方弧形选择区（未上滑时显示中间「松开 发送」）。
    private var voiceRecordingOverlay: some View {
        VStack(spacing: 8) {
            voiceWaveform
            ZStack {
                if showActionLayer {
                    arcActionLayer
                        .transition(.scale(scale: 0.15, anchor: .bottom).combined(with: .opacity))
                } else {
                    centerSendHint
                        .transition(.opacity)
                }
            }
            .frame(height: 104)
        }
        // 纯视觉浮层：不拦截触摸，手势始终由下方「按住 说话」接管
        .allowsHitTesting(false)
    }

    /// 语音波形：实时音量频谱条（EQ 样式），高度随 audioLevel 起伏；右上角显示已录时长。
    private var voiceWaveform: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 3) {
                    ForEach(0..<22, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.openClawRed.opacity(0.85))
                            .frame(width: 4, height: waveformBarHeight(index: index, time: time))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color(.systemBackground).opacity(0.92)))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 2)

                Text(recordingDurationText)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.trailing, 24)
            }
        }
    }

    /// 已录时长（秒）。
    private var recordingDurationText: String {
        let elapsed = max(0, Date().timeIntervalSince(recordingStart ?? Date()))
        return "\(Int(elapsed))″"
    }

    /// 频谱条高度：基线 + 时间相位起伏 + 实时音量（audioLevel 0~1）。
    private func waveformBarHeight(index: Int, time: TimeInterval) -> CGFloat {
        let level = min(max(audioLevel, 0.02), 1)
        let phase = Double(index) * 0.6
        let wave = (sin(time * 2.8 + phase) + 1) / 2
        let base = 8 + Double(index % 6) * 1.8
        let height = base + wave * 16 + Double(level) * 24
        return CGFloat(min(max(height, 4), 40))
    }

    /// 中间提示：录音中「松开 发送」。
    private var centerSendHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.openClawRed)
            Text("松开 发送")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(Capsule().fill(.regularMaterial))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    /// 微信弧形选择层：中心「松开 发送」，两侧弧线展开（左「取消」红 / 右「滑到这里转文字」绿）。
    /// 弧形几何与手势命中一致：以拇指位置为圆心，按「角度 + 距离」命中侧弧。
    private var arcActionLayer: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let anchorX = width / 2
            let anchorY = height
            // 45° 弧位（与 updateArcSelection 的角度区间一致）
            let arcOffset: CGFloat = 40
            let leftCenter = CGPoint(x: anchorX - arcOffset, y: anchorY - arcOffset)
            let rightCenter = CGPoint(x: anchorX + arcOffset, y: anchorY - arcOffset)

            ZStack {
                arcGuidePath(
                    width: width,
                    height: height,
                    leftSelected: selectedAction == .cancel,
                    rightSelected: selectedAction == .transcribe
                )

                arcActionButton(
                    title: "取消",
                    icon: "xmark",
                    tint: .red,
                    action: .cancel,
                    center: leftCenter
                )

                arcActionButton(
                    title: "滑到这里转文字",
                    icon: "textformat",
                    tint: .green,
                    action: .transcribe,
                    center: rightCenter
                )

                centerSendHint
                    .position(x: anchorX, y: 20)
            }
        }
    }

    /// 弧形引导线：连接左右弧位的顶部弧线；命中侧弧时该侧高亮。
    private func arcGuidePath(width: CGFloat, height: CGFloat, leftSelected: Bool, rightSelected: Bool) -> some View {
        let center = CGPoint(x: width / 2, y: height)
        let radius: CGFloat = 46
        let leftStart = Angle.degrees(200)
        let mid = Angle.degrees(270)
        let rightEnd = Angle.degrees(340)
        return ZStack {
            Path { path in
                path.addArc(center: center, radius: radius, startAngle: leftStart, endAngle: mid, clockwise: true)
            }
            .stroke(leftSelected ? Color.red : Color(.systemGray3), style: StrokeStyle(lineWidth: 3, lineCap: .round))

            Path { path in
                path.addArc(center: center, radius: radius, startAngle: mid, endAngle: rightEnd, clockwise: true)
            }
            .stroke(rightSelected ? Color.green : Color(.systemGray3), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    /// 弧形按钮：左「取消」红 / 右「滑到这里转文字」绿；命中时弹性放大（spring 吸附）。
    private func arcActionButton(title: String, icon: String, tint: Color, action: HoldAction, center: CGPoint) -> some View {
        let isSelected = selectedAction == action
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
            Text(title)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Capsule().fill(tint.opacity(isSelected ? 1.0 : 0.55)))
        .overlay(Capsule().strokeBorder(.white.opacity(isSelected ? 0.45 : 0), lineWidth: 1.5))
        .shadow(color: tint.opacity(isSelected ? 0.45 : 0.18), radius: isSelected ? 10 : 6, y: 3)
        .scaleEffect(isSelected ? 1.12 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isSelected)
        .position(x: center.x, y: center.y)
    }

    private func toggleVoiceMode() {
        isVoiceMode.toggle()
        if isVoiceMode {
            isInputFocused = false
        } else {
            isInputFocused = true
        }
        onToggleVoiceMode()
    }
}
