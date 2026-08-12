import SwiftUI
import UIKit

/// 随身语音助手主卡片：点按开始/结束连续对讲，长按退出。
///
/// Siri 风格整卡灵动（明哥拍板 v037 重做）：无按钮、无内框，
/// 整张卡片就是动态主体——背景三团流动彩带（红→紫→蓝）缓慢游走、
/// 悬浮光点漂移、整卡呼吸透明度；状态切换时整卡动作跟着变化：
/// - idle（待机）：彩带慢速流动 + 光点漂浮 + 文字呼吸（卡片始终「着」）
/// - listening（聆听中）：中央波纹扩散到整卡 + 彩带加速
/// - thinking（思考中）：中央旋转光点 + 彩带轻缓
/// - speaking（播报中）：整卡快速脉动 + 呼吸光罩
///
/// 说明：卡片自身不再绘制渐变底/描边（由 VoiceAssistantCardSlot 统一提供），
/// 本视图负责整卡动画内容层 + 点按反馈 + 顶部操作栏。
struct VoiceAssistantCardView: View, VoiceAssistantCardContent {
    @Bindable var viewModel: VoiceAssistantViewModel
    /// 语音快捷设置（齿轮）数据源
    @Bindable var settingsStore: SettingsStore

    // 首次使用引导是否显示
    @State private var showFirstUseGuide = false
    // 实时转写逐字冒出
    @State private var revealedTranscriptCount = 0
    @State private var revealedTranscriptText = ""
    @State private var transcriptRevealTask: Task<Void, Never>?
    // 点按反馈：按下收缩 / 松手回弹
    @State private var pressed = false
    @State private var pressStart: Date?
    // 待机文字呼吸
    @State private var textBreathing = false
    // 待机提示轮播
    @State private var tipIndex = 0
    @State private var tipTask: Task<Void, Never>?
    // 齿轮 → 语音快捷设置
    @State private var showQuickSettings = false
    // 大卡主题（AppStorage 持久化，齿轮设置里切换）
    @AppStorage("voiceAssistant.theme") private var themeRawValue = VoiceAssistantTheme.aurora.rawValue
    // 对话记录入口
    @State private var showTranscript = false

    private let cardHeight: CGFloat = 250
    private let firstUseDefaultsKey = "voiceAssistant.didShowFirstUseGuide"

    /// 当前主题（AppStorage rawValue 映射；未知值回退极光）。
    private var theme: VoiceAssistantTheme {
        VoiceAssistantTheme(rawValue: themeRawValue) ?? .aurora
    }

    init(viewModel: VoiceAssistantViewModel, settingsStore: SettingsStore) {
        self.viewModel = viewModel
        self.settingsStore = settingsStore
    }

    var body: some View {
        ZStack {
            // 整卡流动彩带（Siri 风，四态共用一套背景，速度/亮度随状态变化）
            SiriBackgroundLayer(state: viewModel.state, theme: theme)
            // 主题动画层：每套主题完全不同的动画效果（频谱条/呼吸光带/星尘/水波/极光流）
            ThemeAnimationLayer(
                state: viewModel.state,
                theme: theme,
                micLevel: viewModel.audioLevel,
                micActive: viewModel.isMicActive
            )

            contentOverlay
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .scaleEffect(pressed ? 0.97 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .gesture(cardGesture)
        .simultaneousGesture(pressFeedbackGesture)
        .overlay(alignment: .top) { topBar }
        .brightness(viewModel.sceneMode.cardBrightnessAdjustment)
        .animation(.easeInOut(duration: 0.35), value: viewModel.state)
        .sheet(isPresented: $showQuickSettings) {
            VoiceAssistantQuickSettingsSheet(
                viewModel: viewModel,
                settingsStore: settingsStore,
                themeRawValue: $themeRawValue
            )
        }
        .sheet(isPresented: $showTranscript) {
            VoiceAssistantTranscriptSheet(viewModel: viewModel)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("随身语音助手，\(statusText)。轻点开始或结束对话，长按退出，右上角切换场景与语音设置。")
        .onAppear {
            maybeShowFirstUseGuide()
            startTipRotation()
            startTextBreathing()
        }
        .onDisappear {
            stopTipRotation()
            stopTextBreathing()
        }
        .onChange(of: viewModel.state) { _, newState in
            handleStateChange(newState)
            syncLiveActivity(newState)
        }
        .onChange(of: viewModel.lastTranscript) { _, _ in
            if viewModel.voiceAssistantShowTranscript,
               viewModel.state == .listening || viewModel.state == .thinking {
                startTranscriptReveal()
            }
        }
    }

    // MARK: - 中央内容（状态大字 + 提示/转写）

    private var contentOverlay: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            Text(statusText)
                .font(.system(size: 27.0 * sceneFontScale, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(viewModel.state == .idle ? (textBreathing ? 1.03 : 1.0) : 1.0)
                .opacity(viewModel.state == .idle ? (textBreathing ? 0.9 : 1.0) : 1.0)
                .shadow(color: .white.opacity(0.35), radius: 10)
                .contentTransition(.opacity)

            if showFirstUseGuide {
                Text("点按开始说话 · 长按退出")
                    .font(.system(size: 12.0 * sceneFontScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .transition(.opacity)
            } else if viewModel.state == .idle {
                Text(currentTip)
                    .font(.system(size: 12.0 * sceneFontScale))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .id("tip-\(tipIndex)")
                    .transition(.opacity.combined(with: .offset(y: 3)))
            } else {
                liveTextArea
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - 手势：短按切换 / 长按退出（主手势，兼容滚动）

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
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .second:
                let willStart = viewModel.state == .idle
                viewModel.toggle()
                // 开始对讲中震动反馈，结束轻反馈。
                UIImpactFeedbackGenerator(style: willStart ? .medium : .light).impactOccurred()
            }
        }
    }

    /// 点按反馈：按下瞬间卡片轻微收缩 + 轻触觉；开始滚动/松手时回弹。
    /// 只做视觉与触觉反馈，不触发任何动作（动作由 cardGesture 决定），
    /// 这样不影响主页 ScrollView 的滚动识别。
    private var pressFeedbackGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStart == nil {
                    pressStart = Date()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) {
                        pressed = true
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else if abs(value.translation.width) > 8 || abs(value.translation.height) > 8 {
                    // 手指开始移动（滚动主页）：撤销按下反馈，避免滚动时误触感
                    pressStart = nil
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.6)) {
                        pressed = false
                    }
                }
            }
            .onEnded { _ in
                pressStart = nil
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                    pressed = false
                }
            }
    }

    // MARK: - 顶部操作栏（长按退出角标 + 语音设置齿轮 + 场景切换）

    private var topBar: some View {
        HStack {
            if viewModel.isActive {
                Text("长按退出")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.28)))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Spacer()
            Button {
                showTranscript = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("对话记录")
            Button {
                showQuickSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("语音设置")
            Button {
                viewModel.cycleSceneMode()
            } label: {
                Image(systemName: sceneModeIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换场景模式，当前\(viewModel.sceneMode.displayName)")
        }
        .padding(14)
    }

    private var sceneModeIcon: String {
        switch viewModel.sceneMode {
        case .normal: return "sun.max.fill"
        case .driving: return "car.fill"
        case .night: return "moon.stars.fill"
        }
    }

    // MARK: - 待机文字呼吸与提示轮播

    private func startTextBreathing() {
        textBreathing = false
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            textBreathing = true
        }
    }

    private func stopTextBreathing() {
        withAnimation(.easeInOut(duration: 0.2)) {
            textBreathing = false
        }
    }

    private let idleTips = [
        "说：帮我记一笔账",
        "说：开车去公司",
        "说：明天 9 点提醒我开会",
        "说：读一篇今天的日记"
    ]

    private var currentTip: String {
        idleTips[tipIndex % idleTips.count]
    }

    private func startTipRotation() {
        tipTask?.cancel()
        tipTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    tipIndex = (tipIndex + 1) % idleTips.count
                }
            }
        }
    }

    private func stopTipRotation() {
        tipTask?.cancel()
        tipTask = nil
    }

    // MARK: - 首次使用引导

    /// 第一次出现时展示小字提示，几秒后淡出；用 UserDefaults 记 flag，之后不再显示。
    private func maybeShowFirstUseGuide() {
        guard !UserDefaults.standard.bool(forKey: firstUseDefaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: firstUseDefaultsKey)
        showFirstUseGuide = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard showFirstUseGuide else { return }
            withAnimation(.easeOut(duration: 0.6)) {
                showFirstUseGuide = false
            }
        }
    }

    // MARK: - 实时转写/回复文字

    /// 实时文字区：聆听/思考显示逐字冒出的转写，播报显示回复；开关关闭时为空。
    @ViewBuilder
    private var liveTextArea: some View {
        if viewModel.voiceAssistantShowTranscript {
            switch viewModel.state {
            case .listening, .thinking:
                Text(transcriptDisplayText)
                    .font(.system(size: 12.0 * sceneFontScale))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .id("transcript")
                    .transition(.opacity.combined(with: .offset(y: 4)))
            case .speaking:
                Text(viewModel.lastReply)
                    .font(.system(size: 12.0 * sceneFontScale))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .id("reply")
                    .transition(.opacity.combined(with: .offset(y: 4)))
            case .idle:
                EmptyView()
            }
        }
    }

    /// 逐字冒出：已显示前缀 + 未播完时的光标。
    private var transcriptDisplayText: String {
        let full = viewModel.lastTranscript
        let shown = String(full.prefix(revealedTranscriptCount))
        let isRevealing = !full.isEmpty && revealedTranscriptCount < full.count
        return isRevealing ? shown + "▍" : shown
    }

    /// 状态切换时维护逐字任务：聆听/思考开始或继续冒出，播报/空闲停止。
    private func handleStateChange(_ newState: VoiceAssistantState) {
        switch newState {
        case .listening, .thinking:
            if viewModel.voiceAssistantShowTranscript {
                startTranscriptReveal()
            }
        case .speaking, .idle:
            stopTranscriptReveal()
        }
    }

    /// 开始逐字冒出（同段文字已完整显示时跳过，避免每轮聆听重播旧转写）。
    private func startTranscriptReveal() {
        let text = viewModel.lastTranscript
        guard !text.isEmpty else {
            revealedTranscriptCount = 0
            revealedTranscriptText = ""
            return
        }
        guard text != revealedTranscriptText || revealedTranscriptCount < text.count else { return }
        transcriptRevealTask?.cancel()
        revealedTranscriptCount = 0
        revealedTranscriptText = text
        transcriptRevealTask = Task { @MainActor in
            var count = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000)
                if Task.isCancelled { return }
                count = min(count + 2, text.count)
                withAnimation(.easeOut(duration: 0.08)) {
                    revealedTranscriptCount = count
                }
                if count >= text.count { return }
            }
        }
    }

    private func stopTranscriptReveal() {
        transcriptRevealTask?.cancel()
        transcriptRevealTask = nil
    }

    // MARK: - D. 灵动岛/锁屏联动

    /// 语音助手状态同步到灵动岛/锁屏：聆听开启卡片，思考/播报更新，空闲结束。
    private func syncLiveActivity(_ state: VoiceAssistantState) {
        if #available(iOS 16.1, *) {
            switch state {
            case .listening:
                ClawTalkLiveActivity.startVoiceAssistant(status: "聆听中…")
            case .thinking:
                ClawTalkLiveActivity.update(statusText: "思考中…", icon: "🎙️")
            case .speaking:
                ClawTalkLiveActivity.update(statusText: "播报中…", icon: "🎙️")
            case .idle:
                ClawTalkLiveActivity.endVoiceAssistant()
            }
        }
    }

    // MARK: - 派生样式

    private var sceneFontScale: CGFloat {
        viewModel.sceneMode.statusFontScale
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle: return "点按说话"
        case .listening: return "聆听中…"
        case .thinking: return "思考中…"
        case .speaking: return "播报中…"
        }
    }
}

// MARK: - 整卡流动彩带（Siri 风）

private struct SiriBackgroundLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speed = speedFactor
            // 整卡呼吸透明度（待机也有「活」感，0.82 ↔ 1.0）
            let breathing = 0.82 + 0.18 * abs(sin(t * 1.3))
            // 极光流主题让彩带成为主角；其余主题压暗彩带，突出各自动画层。
            let intensity = theme.style == .auroraFlow ? 1.0 : 0.55
            GeometryReader { geo in
                ZStack {
                    // 主色带：环形渐变绕中心旋转（Siri 绸缎流动感）
                    AngularGradient(
                        colors: theme.ribbonColors,
                        center: .center,
                        angle: .degrees(360 * (t * 0.05 * speed).truncatingRemainder(dividingBy: 1.0))
                    )
                    .blur(radius: 70)
                    .scaleEffect(1.25)
                    .opacity(intensity)

                    // 反向慢速微光带（叠加发光，交叉处自然提亮）
                    AngularGradient(
                        colors: [
                            Color.white.opacity(0.07),
                            Color.clear,
                            Color.white.opacity(0.05),
                            Color.clear
                        ],
                        center: .center,
                        angle: .degrees(360 * (t * 0.03 * speed).truncatingRemainder(dividingBy: 1.0))
                    )
                    .blur(radius: 60)
                    .scaleEffect(1.3)
                    .opacity(intensity * 0.9)

                    // 中央高亮（Siri 的光聚在中间）
                    RadialGradient(
                        colors: [.white.opacity(0.16), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: geo.size.width * 0.55
                    )

                    // 边缘暗角（层次感）
                    RadialGradient(
                        colors: [.clear, .black.opacity(0.32)],
                        center: .center,
                        startRadius: geo.size.width * 0.42,
                        endRadius: max(geo.size.width, geo.size.height) * 0.75
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .opacity(breathing)
            }
        }
        .allowsHitTesting(false)
    }

    /// 待机最慢（安静呼吸），聆听/播报加速（有「反应」）。
    private var speedFactor: Double {
        switch state {
        case .idle: return 0.55
        case .listening: return 1.0
        case .thinking: return 0.8
        case .speaking: return 1.25
        }
    }
}

// MARK: - 主题动画层（每套主题完全不同的动画效果）

/// 按主题风格渲染整套动画：频谱条 / 呼吸光带 / 粒子星尘 / 同心水波 / 极光流。
/// 每套风格都是独立实现（不只是换底色），待机/聆听/思考/播报四态各自有不同的动态。
private struct ThemeAnimationLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    var body: some View {
        switch theme.style {
        case .spectrum:
            SpectrumBarsView(state: state, theme: theme, micLevel: micLevel, micActive: micActive)
        case .breathingBand:
            BreathingBandView(state: state, theme: theme, micLevel: micLevel, micActive: micActive)
        case .stardust:
            StardustView(state: state, theme: theme, micLevel: micLevel, micActive: micActive)
        case .ripple:
            RippleRingsView(state: state, theme: theme, micLevel: micLevel, micActive: micActive)
        case .auroraFlow:
            AuroraFlowLayer(state: state, theme: theme, micLevel: micLevel, micActive: micActive)
        }
    }
}

/// 当前「音量幅度」：对讲中（麦克风引擎在跑）= 真实麦克风 RMS（上限 1.0）；
/// 待机（引擎已停，诚实实现）= 主题低幅伪随机微澜，同一时刻同一相位稳定不闪烁。
private func ambientLevel(
    state: VoiceAssistantState,
    theme: VoiceAssistantTheme,
    micLevel: Float,
    micActive: Bool,
    t: TimeInterval,
    phase: Double
) -> Double {
    if state != .idle && micActive {
        return Double(min(micLevel * 6.0, 1.0))
    }
    return theme.idleAmplitude * (0.40 + 0.60 * abs(sin(t * 1.3 + phase * 1.7)))
}

// MARK: - 主题1：频谱条（EQ 竖条随音量跳动）

/// 音箱 EQ 频谱：14 根粗圆头竖条 + 底部镜像倒影，中央条更活跃；
/// 对讲中跟随真实麦克风音量跳动，待机低幅微澜。
private struct SpectrumBarsView: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    private let barCount = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let centerX = geo.size.width / 2
                let barWidth = min(9.0, geo.size.width * 0.045)
                let gap = barWidth * 0.55
                let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
                let startX = centerX - totalWidth / 2 + barWidth / 2
                let baseY = geo.size.height * 0.76
                let maxHeight = geo.size.height * 0.32
                ZStack {
                    ForEach(0..<barCount, id: \.self) { index in
                        let level = spectrumLevel(index: index, t: t)
                        let height = max(4.0, maxHeight * level)
                        let x = startX + CGFloat(index) * (barWidth + gap)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.accentColor.opacity(0.95),
                                        .white.opacity(0.8)
                                    ],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(width: barWidth, height: height)
                            .shadow(color: theme.accentColor.opacity(0.5), radius: 3)
                            .position(x: x, y: baseY - height / 2)
                        Capsule()
                            .fill(theme.accentColor.opacity(0.20))
                            .frame(width: barWidth, height: height * 0.42)
                            .position(x: x, y: baseY + height * 0.21)
                    }
                }
                .opacity(state == .idle ? 0.95 : 0.85)
            }
        }
        .allowsHitTesting(false)
    }

    /// 单根频谱条高度：对讲中 = 麦克风幅度 × 抖动 + 中央偏置；待机 = 确定性微澜。
    private func spectrumLevel(index: Int, t: TimeInterval) -> Double {
        let phase = Double(index) * 0.53
        let centerBias = 0.72 + 0.28 * cos(Double(index - barCount / 2) * 0.55)
        if state != .idle && micActive {
            let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: phase)
            let wobble = 0.5 + 0.5 * abs(sin(t * 3.4 + phase))
            return min(1.0, amp * 1.35 * wobble * centerBias + 0.05)
        }
        let sweep = abs(sin(t * 0.9 + Double(index) * 0.34))
        let idle = theme.idleAmplitude * (0.35 + 0.65 * sweep) * centerBias
        return max(0.05, min(0.5, idle))
    }
}

// MARK: - 主题2：呼吸光带（整条光带呼吸 + 高光流动）

/// 深海风格：一条横向渐变光带呼吸明暗，白色高光在带内来回流动；
/// 聆听/播报时光带更亮、高光更快，待机缓慢呼吸。
private struct BreathingBandView: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let bandWidth = geo.size.width * 0.66
                let bandHeight: CGFloat = state == .idle ? 10 : 15
                let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: 0)
                let breathe = 0.35 + 0.65 * abs(sin(t * theme.idleSpeed * 1.6))
                let boost = state == .idle ? 1.0 : (0.85 + 0.15 * amp)
                let centerX = geo.size.width / 2
                let y = geo.size.height * 0.76
                let highlightOffset = bandWidth * 0.30 * sin(t * theme.idleSpeed * 0.9)
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.22),
                                    theme.accentColor.opacity(0.78 * breathe * boost),
                                    theme.accentColor.opacity(0.22)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: bandWidth, height: bandHeight)
                        .blur(radius: 2)
                        .shadow(color: theme.accentColor.opacity(0.35 * boost), radius: 8)
                        .position(x: centerX, y: y)
                    Capsule()
                        .fill(.white.opacity(0.55 * breathe * boost))
                        .frame(width: bandWidth * 0.24, height: bandHeight * 0.45)
                        .blur(radius: 4)
                        .position(x: centerX + highlightOffset, y: y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 主题3：粒子星尘（漂浮粒子随音量聚散）

/// 暗夜风格：星尘粒子群，聆听/播报时向中心聚拢变亮（随音量增强），
/// 待机缓慢散开漂浮；中心带随音量浮现的柔光。
private struct StardustView: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    private let count = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: 0.4)
                let gather = state == .idle ? 0.10 : 0.35 + 0.55 * amp
                let spread = 1.0 - gather * 0.85
                let centerX = geo.size.width / 2
                let baseY = geo.size.height * 0.68
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [theme.accentColor.opacity(0.30 * gather), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: geo.size.width * 0.30
                            )
                        )
                        .frame(width: geo.size.width * 0.6, height: geo.size.height * 0.5)
                        .position(x: centerX, y: baseY)
                    ForEach(0..<count, id: \.self) { index in
                        let phase = Double(index) * 1.7
                        let anchorX = Double(index % 6) / 5.0 - 0.5
                        let anchorY = Double(index / 6) / 2.0 - 0.5
                        let driftX = sin(t * theme.idleSpeed * 0.6 + phase) * 0.30
                        let driftY = cos(t * theme.idleSpeed * 0.5 + phase * 0.8) * 0.18
                        let x = centerX + CGFloat((anchorX * 0.42 + driftX) * spread) * geo.size.width
                        let y = baseY + CGFloat((anchorY * 0.10 + driftY * 0.08)) * geo.size.height
                        let twinkle = 0.5 + 0.5 * sin(t * 2.0 + phase)
                        Circle()
                            .fill(.white.opacity(theme.particleOpacity * (0.22 + 0.50 * twinkle * (0.4 + amp))))
                            .frame(width: 3.5 + CGFloat(index % 3) * 1.8 + CGFloat(amp * 3.0))
                            .position(x: x, y: y)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 主题4：同心水波（从中心连续扩散的圆环）

/// 落日风格：从中心连续扩散的同心圆环，聆听时发射更快、更亮，
/// 中心亮核随音量放大；待机缓慢涟漪。
private struct RippleRingsView: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    private let ringCount = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: 0)
                let centerX = geo.size.width / 2
                let centerY = geo.size.height * 0.60
                let maxRadius = geo.size.height * 0.52
                let speed = (state == .idle ? 0.30 : (state == .speaking ? 0.80 : 0.55)) + amp * 0.35
                ZStack {
                    ForEach(0..<ringCount, id: \.self) { index in
                        let progress = (t * speed * 0.9 + Double(index) * 0.25).truncatingRemainder(dividingBy: 1.0)
                        let radius = maxRadius * progress
                        let opacity = (1.0 - progress) * (state == .idle ? 0.26 : 0.42)
                        Circle()
                            .stroke(theme.accentColor.opacity(opacity), lineWidth: progress < 0.15 ? 2.5 : 1.6)
                            .frame(width: radius * 2, height: radius * 2)
                            .position(x: centerX, y: centerY)
                    }
                    Circle()
                        .fill(theme.accentColor.opacity(0.5 + amp * 0.4))
                        .frame(width: 8 + amp * 6, height: 8 + amp * 6)
                        .blur(radius: 2)
                        .position(x: centerX, y: centerY)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 主题5：极光流（彩色渐变帘流动扫过）

/// 极光风格：在彩带基础上叠两道对角流动的极光帘 + 中央光晕，
/// 聆听/播报时流速加快、更亮；待机舒缓流动。
private struct AuroraFlowLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: 0.2)
                let speed = (state == .idle ? 0.8 : (state == .speaking ? 2.0 : 1.4)) + amp * 0.8
                let brightness = 0.6 + amp
                let sweep = (t * speed * 0.12).truncatingRemainder(dividingBy: 1.0)
                let sweep2 = (t * speed * 0.07 + 0.5).truncatingRemainder(dividingBy: 1.0)
                ZStack {
                    LinearGradient(
                        colors: [
                            .clear,
                            theme.accentColor.opacity(0.22 * brightness),
                            .white.opacity(0.14 * brightness),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.55, height: geo.size.height)
                    .blur(radius: 26)
                    .rotationEffect(.degrees(-12))
                    .offset(x: geo.size.width * (sweep * 1.6 - 0.8), y: 0)
                    RadialGradient(
                        colors: [.white.opacity(0.10 * brightness), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: geo.size.width * 0.5
                    )
                    .frame(width: geo.size.width * 0.7, height: geo.size.height * 0.8)
                    .offset(x: geo.size.width * (sweep2 * 1.4 - 0.7), y: 0)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
// MARK: - 语音快捷设置（齿轮入口）

/// 语音大卡右上角齿轮弹出的快捷设置：对讲/唤醒开关 + 场景模式 +
/// 大卡主题（5 套）+ 文字转语音（提供商/音色/语速/音调/试听）+ 语音转文字（提供商/语言）。
struct VoiceAssistantQuickSettingsSheet: View {
    @Bindable var viewModel: VoiceAssistantViewModel
    @Bindable var settingsStore: SettingsStore
    @Binding var themeRawValue: String
    @Environment(\.dismiss) private var dismiss

    // 试听（TTS 预览）状态
    @State private var previewService: (any SpeechService)?
    @State private var previewPlayback: AudioPlaybackManager?
    @State private var isPreviewing = false
    @State private var previewErrorMessage: String?

    init(viewModel: VoiceAssistantViewModel, settingsStore: SettingsStore, themeRawValue: Binding<String>) {
        self.viewModel = viewModel
        self.settingsStore = settingsStore
        self._themeRawValue = themeRawValue
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("对讲") {
                    Toggle(
                        "语音输入（语音转文字）",
                        isOn: savedBinding(\.voiceInputEnabled)
                    )
                    Toggle(
                        "语音输出（文字转语音）",
                        isOn: savedBinding(\.voiceOutputEnabled)
                    )
                    Toggle(
                        "显示实时转写",
                        isOn: savedBinding(\.voiceAssistantShowTranscript)
                    )
                }
                Section("语音唤醒") {
                    Toggle("语音唤醒", isOn: savedBinding(\.voiceWakeEnabled))
                    if settingsStore.settings.voiceWakeEnabled {
                        Text(wakeWordsText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("场景模式") {
                    Picker("场景", selection: $viewModel.sceneMode) {
                        ForEach(VoiceSceneMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("大卡主题") {
                    Picker("主题", selection: $themeRawValue) {
                        ForEach(VoiceAssistantTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section("文字转语音") {
                    Picker("提供商", selection: valueBinding(\.ttsProvider)) {
                        ForEach(TTSProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    switch settingsStore.settings.ttsProvider {
                    case .apple:
                        previewButton
                    case .doubao:
                        SecureField("豆包 API Key", text: $settingsStore.doubaoAPIKey)
                            .textContentType(.password)
                        Picker("音色", selection: valueBinding(\.doubaoVoiceID)) {
                            Text("鸡汤妹妹 Hope 2.0").tag("zh_female_jitangmei_uranus_bigtts")
                            Text("温柔淑女 2.0").tag("zh_female_wenroushunv_uranus_bigtts")
                            Text("甜美小源 2.0").tag("zh_female_tianmeixiaoyuan_uranus_bigtts")
                            Text("渊博小叔 2.0").tag("zh_male_yuanboxiaoshu_uranus_bigtts")
                            Text("爽朗少年 Brayan 2.0").tag("zh_male_shaonianzixin_uranus_bigtts")
                        }
                        TextField("自定义音色 ID", text: valueBinding(\.doubaoVoiceID))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        previewButton
                    case .edge:
                        Picker("音色", selection: valueBinding(\.edgeVoiceID)) {
                            Text("晓晓（女）").tag("zh-CN-XiaoxiaoNeural")
                            Text("小艺").tag("zh-CN-XiaoyiNeural")
                            Text("云希（男）").tag("zh-CN-YunxiNeural")
                            Text("云扬（男）").tag("zh-CN-YunyangNeural")
                            Text("云健（男）").tag("zh-CN-YunjianNeural")
                            Text("云夏（女）").tag("zh-CN-YunxiaNeural")
                        }
                        previewButton
                    }
                    if settingsStore.settings.ttsProvider != .doubao {
                        speedSlider
                        pitchSlider
                    }
                }
                Section("语音转文字") {
                    Picker("提供商", selection: valueBinding(\.sttProvider)) {
                        ForEach(STTProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    switch settingsStore.settings.sttProvider {
                    case .apple:
                        Picker("识别语言", selection: valueBinding(\.whisperLanguage)) {
                            Text("中文").tag("zh")
                            Text("跟随系统").tag("auto")
                        }
                    case .doubao:
                        SecureField("豆包 API Key", text: $settingsStore.doubaoAPIKey)
                            .textContentType(.password)
                    }
                }
            }
            .navigationTitle("语音设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert("试听失败", isPresented: Binding(
            get: { previewErrorMessage != nil },
            set: { if !$0 { previewErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(previewErrorMessage ?? "")
        }
    }

    /// 生成「修改即保存」的绑定（AppSettings 非 Equatable，逐字段绑定最稳）。
    private func savedBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { newValue in
                settingsStore.settings[keyPath: keyPath] = newValue
                settingsStore.save()
            }
        )
    }

    private var wakeWordsText: String {
        let words = settingsStore.settings.voiceWakeWords
        return words.isEmpty ? "未设置唤醒词" : "唤醒词：\(words.joined(separator: "、"))"
    }

    // MARK: - 通用「修改即保存」绑定

    /// 通用绑定（Equatable 字段：提供商/音色/识别语言等），修改立即写回并保存。
    private func valueBinding<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { newValue in
                settingsStore.settings[keyPath: keyPath] = newValue
                settingsStore.save()
            }
        )
    }

    // MARK: - 语速 / 音调滑块

    private var speedSlider: some View {
        HStack {
            Text("语速")
                .frame(width: 44, alignment: .leading)
            Slider(value: speedBinding, in: -50...50, step: 5)
            Text(speedValueText)
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var pitchSlider: some View {
        HStack {
            Text("音调")
                .frame(width: 44, alignment: .leading)
            Slider(value: pitchBinding, in: -10...10, step: 1)
            Text(pitchValueText)
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { Double(settingsStore.settings.ttsSpeed) },
            set: {
                settingsStore.settings.ttsSpeed = Int($0.rounded())
                settingsStore.save()
            }
        )
    }

    private var pitchBinding: Binding<Double> {
        Binding(
            get: { Double(settingsStore.settings.ttsPitch) },
            set: {
                settingsStore.settings.ttsPitch = Int($0.rounded())
                settingsStore.save()
            }
        )
    }

    private var speedValueText: String {
        let v = settingsStore.settings.ttsSpeed
        return v > 0 ? "+\(v)" : "\(v)"
    }

    private var pitchValueText: String {
        let v = settingsStore.settings.ttsPitch
        return v > 0 ? "+\(v)" : "\(v)"
    }

    // MARK: - TTS 试听

    private var previewButton: some View {
        Button {
            if isPreviewing {
                stopPreview()
            } else {
                startPreview()
            }
        } label: {
            Label(isPreviewing ? "停止试听" : "试听音色", systemImage: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
        }
        .disabled(previewDisabled)
    }

    private var previewDisabled: Bool {
        switch settingsStore.settings.ttsProvider {
        case .doubao:
            return settingsStore.doubaoAPIKey.isEmpty
        case .apple, .edge:
            return false
        }
    }

    /// 与设置页同链路：Apple 直接消费流触发 AVSpeechSynthesizer；豆包/Edge 走 PCM + AudioPlaybackManager。
    private func startPreview() {
        let sampleText = "你好，这是你的语音预览。"
        let s = settingsStore.settings

        let tts: any SpeechService
        switch s.ttsProvider {
        case .doubao:
            tts = DoubaoTTSService(apiKey: settingsStore.doubaoAPIKey, voiceID: s.doubaoVoiceID)
        case .apple:
            tts = AppleTTSService(speed: s.ttsSpeed, pitch: s.ttsPitch)
        case .edge:
            tts = EdgeTTSService(voiceID: s.edgeVoiceID, speed: s.ttsSpeed, pitch: s.ttsPitch)
        }
        previewService = tts
        isPreviewing = true

        switch s.ttsProvider {
        case .apple:
            // Apple TTS 通过 AVSpeechSynthesizer 直接发声；必须真正消费流才会开始朗读。
            Task {
                do {
                    for try await _ in tts.streamSpeech(text: sampleText) {}
                } catch {
                    let message = "语音预览失败：\(AppErrorText.localized(error.localizedDescription))"
                    previewErrorMessage = message
                    LogCollector.record(module: "语音预览", message)
                }
            }
            // Apple TTS 无完成回调，4 秒后自动复位。
            Task {
                try? await Task.sleep(for: .seconds(4))
                if isPreviewing { isPreviewing = false }
            }
        default:
            // 豆包 / Edge 返回 PCM，交给 AudioPlaybackManager 播放。
            let playback = AudioPlaybackManager()
            previewPlayback = playback
            Task {
                do {
                    try playback.start()
                    let audioStream = tts.streamSpeech(text: sampleText)
                    for try await chunk in audioStream {
                        playback.enqueue(pcmData: chunk)
                    }
                    playback.markStreamingDone()
                    await playback.waitUntilFinished()
                } catch {
                    let message = "语音预览失败：\(AppErrorText.localized(error.localizedDescription))"
                    previewErrorMessage = message
                    LogCollector.record(module: "语音预览", message)
                }
                playback.stop()
                isPreviewing = false
                previewPlayback = nil
            }
        }
    }

    private func stopPreview() {
        previewService?.stop()
        previewPlayback?.stop()
        previewPlayback = nil
        previewService = nil
        isPreviewing = false
    }
}

// MARK: - 语音大卡「记录」（历史对话记录）

/// 大卡右上角「记录」入口弹出的历史对话列表：真实对讲流水
/// （每轮「用户转写 + 智能体回复」由 ViewModel 落盘），非假数据；
/// 空记录显示诚实空态。
struct VoiceAssistantTranscriptSheet: View {
    @Bindable var viewModel: VoiceAssistantViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [VoiceAssistantTranscriptEntry] = []
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "暂无对话记录",
                        systemImage: "mic.badge.ellipsis",
                        description: Text("开始对讲后，每轮「你说 + 助手答」会自动记录在这里。")
                    )
                } else {
                    List {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                HStack(alignment: .top, spacing: 8) {
                                    Text("我")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(.blue.opacity(0.8)))
                                    Text(entry.userText)
                                        .font(.subheadline)
                                }
                                HStack(alignment: .top, spacing: 8) {
                                    Text("助手")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(.openClawRed))
                                    Text(entry.replyText)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("对话记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("清空", role: .destructive) { confirmClear = true }
                        .disabled(entries.isEmpty)
                }
            }
            .confirmationDialog("清空全部对话记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    viewModel.clearTranscript()
                    entries = []
                }
                Button("取消", role: .cancel) {}
            }
        }
        .onAppear {
            entries = viewModel.transcriptEntries
        }
        .presentationDetents([.medium, .large])
    }
}
