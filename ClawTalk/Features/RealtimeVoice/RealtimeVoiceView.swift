import SwiftUI

/// 实时语音对讲全屏页：状态 + 说话按钮 + 传输模式诚实标注。
/// 接线：由聊天页/语音助手/副主页以 fullScreenCover/sheet 呈现（详见交付报告的接线清单）。
struct RealtimeVoiceView: View {
    @Bindable var session: RealtimeVoiceSession
    var hapticsEnabled: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var isPressed = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var isHolding = false

    private let holdThreshold: UInt64 = 300_000_000  // 0.3s

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer()

            statusArea

            Spacer()

            talkButton

            Spacer()

            annotation
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear { session.startSession() }
        .onDisappear { session.stopSession() }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(.systemGray5), in: Circle())
            }
            .accessibilityLabel("关闭")

            Spacer()

            VStack(spacing: 2) {
                Text("实时语音")
                    .font(.headline)
                Text(session.transportMode.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - 状态区

    private var statusArea: some View {
        VStack(spacing: 10) {
            if let error = session.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text(session.statusText)
                .font(.system(.title2, weight: .semibold))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - 说话按钮（半双工：按住说话）

    private var talkButton: some View {
        ZStack {
            // 录音时外圈电平环
            if session.state == .recording {
                Circle()
                    .stroke(Color.openClawRed.opacity(0.25), lineWidth: 2.5)
                    .frame(
                        width: 96 + CGFloat(session.audioLevel * 60),
                        height: 96 + CGFloat(session.audioLevel * 60)
                    )
                    .animation(.easeOut(duration: 0.08), value: session.audioLevel)
            }

            Circle()
                .fill(buttonColor)
                .frame(width: 92, height: 92)
                .shadow(color: buttonColor.opacity(0.4), radius: isPressed ? 4 : 10, y: isPressed ? 1 : 4)
                .scaleEffect(isPressed ? 0.9 : 1.0)

            Image(systemName: buttonIcon)
                .font(.system(.title, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: 140, height: 140)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed, session.state == .idle else { return }
                    isPressed = true
                    isHolding = false
                    if hapticsEnabled { Haptics.impact(.medium) }
                    holdTimer = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: holdThreshold)
                        guard !Task.isCancelled else { return }
                        isHolding = true
                        if hapticsEnabled { Haptics.impact(.heavy) }
                        session.beginTalk()
                    }
                }
                .onEnded { _ in
                    holdTimer?.cancel()
                    holdTimer = nil
                    guard isPressed else { return }
                    isPressed = false
                    if hapticsEnabled { Haptics.impact(.light) }
                    if isHolding {
                        session.endTalk()
                    }
                }
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPressed)
        .disabled(session.state != .idle && session.state != .recording)
        .accessibilityLabel(session.state == .recording ? "正在聆听，松开发送" : "按住说话")
    }

    private var buttonColor: Color {
        switch session.state {
        case .idle: return .openClawRed
        case .recording: return .red
        case .transcribing, .waitingReply: return .openClawRed.opacity(0.5)
        case .speaking: return .openClawRed.opacity(0.35)
        }
    }

    private var buttonIcon: String {
        switch session.state {
        case .idle, .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .waitingReply: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    // MARK: - 降级诚实标注

    private var annotation: some View {
        HStack(spacing: 6) {
            Image(systemName: session.signalingEndpointConfirmed
                  ? "checkmark.circle"
                  : "antenna.radiowaves.left.and.right.slash")
            Text(session.probeNote)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }
}
