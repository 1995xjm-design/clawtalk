import SwiftUI
import UIKit

/// 微信式输入栏：左侧麦克风/键盘切换 → 中间输入框或「按住 说话」→ 右侧发送箭头/加号。
///
/// 语音模式「按住 说话」：
/// - 按住开始录音（onHoldStart），按钮变红「松开 结束」
/// - 上滑弹出选择层：左侧「取消」/ 右侧「转文字」，手指所在项高亮
/// - 松手：落在取消 → onHoldCancel；落在转文字 → onHoldTranscribe；未上滑 → onHoldSendVoice
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
    @FocusState private var isInputFocused: Bool

    private enum HoldAction {
        case cancel
        case transcribe
    }

    var body: some View {
        HStack(spacing: 10) {
            // 左侧：麦克风/键盘切换
            Button(action: toggleVoiceMode) {
                Image(systemName: isVoiceMode ? "keyboard" : "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
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
            .font(.system(size: 16, weight: .medium))
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
    }

    /// 按住录音 + 上滑选择（取消/转文字），松手按落点触发。
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStart == nil {
                    pressStart = Date()
                    isRecording = true
                    if hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    onHoldStart()
                }
                // 上滑 50pt 进入选择区；按 x 方向决定高亮项（左取消 / 右转文字）
                if value.translation.height < -50 {
                    let newAction: HoldAction = value.translation.width >= 0 ? .transcribe : .cancel
                    if !showActionLayer {
                        // 进入选择区：中震动反馈
                        if hapticsEnabled {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showActionLayer = true
                        }
                    } else if newAction != selectedAction {
                        // 左右切换：轻震动反馈
                        if hapticsEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    selectedAction = newAction
                }
            }
            .onEnded { value in
                pressStart = nil
                isRecording = false
                if hapticsEnabled {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                if showActionLayer && value.translation.height < -50 {
                    switch selectedAction {
                    case .cancel:
                        onHoldCancel()
                    case .transcribe:
                        onHoldTranscribe()
                    case nil:
                        onHoldSendVoice()
                    }
                } else {
                    onHoldSendVoice()
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    showActionLayer = false
                    selectedAction = nil
                }
            }
    }

    /// 录音浮层：上方语音波形（手指上方约 100pt），下方上滑选择区（波形下方、不与波形重叠）。
    private var voiceRecordingOverlay: some View {
        VStack(spacing: 8) {
            voiceWaveform
            if showActionLayer {
                actionLayer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// 语音波形：实时音量频谱条（EQ 样式），高度随 audioLevel 起伏。
    private var voiceWaveform: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
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
        }
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

    /// 上滑选择区：左「取消」/ 右「滑到这里转文字」，大区域（约 112pt 高、约 80% 宽）。
    private var actionLayer: some View {
        HStack(spacing: 12) {
            actionZoneItem("取消", icon: "xmark", tint: .red, action: .cancel)
            actionZoneItem("滑到这里转文字", icon: "textformat", tint: .green, action: .transcribe)
        }
        .padding(.horizontal, 28)
        .frame(height: 112)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        )
    }

    private func actionZoneItem(_ title: String, icon: String, tint: Color, action: HoldAction) -> some View {
        let isSelected = selectedAction == action
        return VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(isSelected ? 0.95 : 0.45))
        )
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.12), value: selectedAction)
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