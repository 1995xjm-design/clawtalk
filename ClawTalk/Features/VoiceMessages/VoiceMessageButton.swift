import SwiftUI

/// 聊天输入区的「语音消息」按钮：按住录音 → 松开发送语音消息。
/// 手势模型与 InlineMicButton 一致（0.3s 长按判定），区别是走语音消息发送链路
/// （本地存档 + 附件标记，网关不支持语音附件时降级 STT 文字并诚实标注）。
struct VoiceMessageButton: View {
    let isRecording: Bool
    let hapticsEnabled: Bool
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void

    @State private var isPressed = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var isHolding = false

    private let size: CGFloat = 40
    private let holdThreshold: UInt64 = 300_000_000  // 0.3s

    var body: some View {
        ZStack {
            Circle()
                .fill(isRecording ? Color.red : Color(.systemGray5))
                .frame(width: size, height: size)
                .scaleEffect(isPressed ? 0.92 : 1.0)
            Image(systemName: isRecording ? "waveform" : "waveform.badge.plus")
                .font(.body)
                .foregroundStyle(isRecording ? .white : .openClawRed)
        }
        .frame(width: size + 12, height: size + 12)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed, !isRecording else { return }
                    isPressed = true
                    isHolding = false
                    if hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                    holdTimer = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: holdThreshold)
                        guard !Task.isCancelled else { return }
                        isHolding = true
                        if hapticsEnabled { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                        onHoldStart()
                    }
                }
                .onEnded { _ in
                    holdTimer?.cancel()
                    holdTimer = nil
                    guard isPressed else { return }
                    isPressed = false
                    if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    if isHolding {
                        onHoldEnd()
                    }
                }
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPressed)
        .disabled(isRecording)
        .accessibilityLabel(isRecording ? "正在录音，松开发送语音消息" : "按住录制语音消息")
    }
}
