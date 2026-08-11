import SwiftUI


/// 随身语音助手主卡片：点按开始/结束连续对讲，长按退出。
///
/// 四种状态动画：
/// - idle（空闲）：呼吸 —— 中心光晕 scale 1.0 → 1.03 循环
/// - listening（聆听中）：波纹扩散 —— 三层 stroke 圆环依次向外扩散并淡出
/// - thinking（思考中）：旋转光点 —— 四个小光点绕中心旋转（ProgressView 风格）
/// - speaking（播报中）：声波跳动 —— 多条竖条按正弦相位起伏，叠加实时输入音量
struct VoiceAssistantCardView: View, VoiceAssistantCardContent {
    @Bindable var viewModel: VoiceAssistantViewModel

    @State private var breathing = false
    @State private var ripplePulse = false

    private let micSize: CGFloat = 72
    private let cardHeight: CGFloat = 200

    init(viewModel: VoiceAssistantViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ZStack {
            // 卡片底
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(cardGradient)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 16, y: 8)

            // 状态动画层
            stateAnimationLayer

            // 麦克风 + 状态文字
            VStack(spacing: 16) {
                micButton
                VStack(spacing: 6) {
                    Text(statusText)
                        .font(.system(size: 18 * sceneFontScale, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(viewModel.sceneMode.hint)
                        .font(.system(size: 12 * sceneFontScale))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .gesture(cardGesture)
        .brightness(viewModel.sceneMode.cardBrightnessAdjustment)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("随身语音助手，\(statusText)。轻点开始或结束对话，长按退出。")
    }

    // MARK: - 手势：短按切换 / 长按退出

    private var cardGesture: some Gesture {
        ExclusiveGesture(
            LongPressGesture(minimumDuration: 0.8),
            TapGesture()
        )
        .onEnded { value in
            switch value {
            case .first:
                // 长按退出（防死循环兜底之一，另一兜底是 ViewModel.maxRounds）。
                viewModel.stopConversation()
            case .second:
                viewModel.toggle()
            }
        }
    }

    // MARK: - 状态动画

    @ViewBuilder
    private var stateAnimationLayer: some View {
        switch viewModel.state {
        case .idle:
            // 呼吸：1.0 → 1.03 循环
            Circle()
                .fill(Color.openClawRed.opacity(0.35))
                .frame(width: micSize, height: micSize)
                .scaleEffect(breathing ? 1.03 : 1.0)
                .blur(radius: 10)
                .onAppear(perform: startBreathing)

        case .listening:
            // 波纹扩散：三层圆环依次向外扩散并淡出
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(Color.openClawRed.opacity(0.55 - Double(index) * 0.15), lineWidth: 2)
                        .frame(width: micSize, height: micSize)
                        .scaleEffect(ripplePulse ? 1.0 + CGFloat(index + 1) * 0.45 : 1.0)
                        .opacity(ripplePulse ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.6)
                                .repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.55),
                            value: ripplePulse
                        )
                }
            }
            .onAppear(perform: startRipple)

        case .thinking:
            // 旋转光点（ProgressView 风格）
            ThinkingOrbitView(color: .openClawRed, size: micSize)

        case .speaking:
            // 声波跳动：竖条随正弦相位起伏，叠加实时音量
            SpeakingWaveformView(level: viewModel.audioLevel, color: .openClawRed)
                .frame(width: 100, height: 56)
        }
    }

    private var micButton: some View {
        ZStack {
            Circle()
                .fill(micFill)
                .frame(width: micSize, height: micSize)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1.5)
                }
                .shadow(color: Color.openClawRed.opacity(0.45), radius: 14, y: 4)

            Image(systemName: micIcon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: viewModel.state == .listening)
        }
    }

    // MARK: - 派生样式

    private var cardGradient: LinearGradient {
        LinearGradient(
            colors: [Color.openClawRed.opacity(0.92), Color.openClawDarkRed],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var sceneFontScale: CGFloat {
        viewModel.sceneMode.statusFontScale
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle: return "空闲"
        case .listening: return "聆听中…"
        case .thinking: return "思考中…"
        case .speaking: return "播报中…"
        }
    }

    private var micFill: Color {
        switch viewModel.state {
        case .idle: return .openClawRed
        case .listening: return .red
        case .thinking: return .openClawRed.opacity(0.65)
        case .speaking: return .openClawRed.opacity(0.85)
        }
    }

    private var micIcon: String {
        switch viewModel.state {
        case .idle, .listening: return "mic.fill"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    // MARK: - 动画开关

    private func startBreathing() {
        breathing = false
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }

    private func startRipple() {
        ripplePulse = false
        ripplePulse = true
    }
}

// MARK: - 思考：旋转光点

private struct ThinkingOrbitView: View {
    let color: Color
    let size: CGFloat

    @State private var spinning = false

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .shadow(color: color.opacity(0.9), radius: 4)
                    .offset(y: -size * 0.42)
                    .rotationEffect(.degrees(Double(index) * 90 + (spinning ? 360 : 0)))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            spinning = false
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

// MARK: - 说话：声波跳动

private struct SpeakingWaveformView: View {
    let level: Float
    let color: Color

    private let barCount = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 6, height: barHeight(at: time, index: index))
                }
            }
        }
    }

    private func barHeight(at time: TimeInterval, index: Int) -> CGFloat {
        let phase = Double(index) * 0.9
        let wave = abs(sin(time * 2.4 + phase))
        let levelBoost = CGFloat(min(max(level, 0), 1)) * 14
        return 10 + wave * 30 + levelBoost
    }
}
