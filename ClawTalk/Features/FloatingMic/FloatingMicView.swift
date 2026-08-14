import SwiftUI
import UIKit

/// 全局语音悬浮球（F4，类似辅助触控）：
/// - 可拖动；拖动结束后吸附到最近侧边
/// - 点按：调用 `onToggle`（App 层决定显示时机/行为）；未提供时默认弹出语音面板
/// - 面板：按住说话 → 松开转写；结果可复制 / 重新说 / 完成
///
/// 用法（App 层）：
/// ```swift
/// content.overlay {
///     FloatingMicOverlay(settingsStore: store) { /* App 层自定义行为 */ }
/// }
/// ```
struct FloatingMicOverlay: View {
    let settingsStore: SettingsStore
    /// 点按悬浮球回调（App 层决定是否弹面板/执行别的动作）。
    var onToggle: (() -> Void)?

    @State private var viewModel: FloatingMicViewModel
    @State private var position: CGPoint
    @State private var isDragging = false
    @State private var showPanel = false

    private let ballSize: CGFloat = 56

    init(settingsStore: SettingsStore, onToggle: (() -> Void)? = nil) {
        self.settingsStore = settingsStore
        self.onToggle = onToggle
        _viewModel = State(initialValue: FloatingMicViewModel(settingsStore: settingsStore))
        _position = State(initialValue: PositionStore.load())
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if showPanel {
                    panel(geo: geo)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
                ball
                    .position(
                        x: position.x * geo.size.width,
                        y: position.y * geo.size.height
                    )
                    .gesture(ballDrag(in: geo.size))
                    .onTapGesture {
                        if let onToggle {
                            onToggle()
                        } else {
                            showPanel.toggle()
                        }
                    }
                    .zIndex(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showPanel)
        .onDisappear {
            if viewModel.state == .recording {
                viewModel.cancelRecording()
            }
        }
    }

    // MARK: - 悬浮球

    private var ball: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.openClawRed, Color.openClawRed.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: ballSize, height: ballSize)
                .shadow(color: Color.openClawRed.opacity(0.4), radius: 6, y: 2)

            Image(systemName: viewModel.state == .transcribing ? "waveform" : "mic.fill")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(.white)

            if viewModel.state == .recording {
                Circle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
                    .frame(width: ballSize, height: ballSize)
                    .scaleEffect(1 + CGFloat(viewModel.audioLevel * 1.2))
                    .opacity(0.7)
            }
        }
        .scaleEffect(isDragging ? 1.12 : 1.0)
        .contentShape(Circle())
        .accessibilityLabel("语音助手")
        .accessibilityHint("点按打开语音助手面板")

    }

    private func ballDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                isDragging = true
                position = CGPoint(
                    x: min(max(value.location.x / size.width, 0.05), 0.95),
                    y: min(max(value.location.y / size.height, 0.12), 0.88)
                )
            }
            .onEnded { _ in
                isDragging = false
                let targetX = position.x < 0.5 ? 0.06 : 0.94
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    position = CGPoint(x: targetX, y: position.y)
                }
                PositionStore.save(position)
            }
    }

    // MARK: - 语音面板

    private func panel(geo: GeometryProxy) -> some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 10)

            Text("全局语音")
                .font(.headline)

            if !viewModel.transcript.isEmpty {
                Text(viewModel.transcript)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            holdToTalkButton

            if !viewModel.transcript.isEmpty {
                HStack(spacing: 12) {
                    Button("复制") { viewModel.copyTranscript() }
                    Button("重新说") { viewModel.clearTranscript() }
                    Spacer()
                    Button("完成") { closePanel() }
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
            } else {
                Button("完成") { closePanel() }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .frame(height: geo.size.height * 0.42)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
    }

    private var holdToTalkButton: some View {
        ZStack {
            Circle()
                .stroke(Color.openClawRed.opacity(0.25), lineWidth: 3)
                .frame(
                    width: 92 + CGFloat(viewModel.audioLevel * 40),
                    height: 92 + CGFloat(viewModel.audioLevel * 40)
                )
            Circle()
                .fill(viewModel.state == .recording ? Color.red : Color.openClawRed)
                .frame(width: 72, height: 72)
                .shadow(color: Color.openClawRed.opacity(0.35), radius: 6, y: 2)
            Image(systemName: viewModel.state == .transcribing ? "waveform" : "mic.fill")
                .font(.system(.title, weight: .medium))
                .foregroundStyle(.white)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if viewModel.state == .idle {
                        viewModel.startRecording()
                    }
                }
                .onEnded { _ in
                    if viewModel.state == .recording {
                        viewModel.stopRecordingAndProcess()
                    }
                }
        )
        .disabled(viewModel.state == .transcribing)
        .accessibilityLabel("按住说话")
    }

    private func closePanel() {
        if viewModel.state == .recording {
            viewModel.cancelRecording()
        }
        viewModel.restoreWakeListening()
        viewModel.clearTranscript()
        showPanel = false
    }
}

/// 悬浮球位置持久化（归一化 0-1，UserDefaults 存两个 Double）。
private enum PositionStore {
    static func load() -> CGPoint {
        let x = UserDefaults.standard.double(forKey: "floating_mic_x")
        let y = UserDefaults.standard.double(forKey: "floating_mic_y")
        guard x > 0, y > 0 else { return CGPoint(x: 0.85, y: 0.6) }
        return CGPoint(x: x, y: y)
    }

    static func save(_ point: CGPoint) {
        UserDefaults.standard.set(point.x, forKey: "floating_mic_x")
        UserDefaults.standard.set(point.y, forKey: "floating_mic_y")
    }
}
