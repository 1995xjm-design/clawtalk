import SwiftUI
import UIKit

/// 随身语音助手主卡片：点按开始/结束连续对讲，长按退出。
///
/// Siri 风格整卡灵动（明哥拍板 v037 重做）：无按钮、无内框，
/// 整张卡片就是动态主体——背景三团流动彩带（红→紫→蓝）缓慢游走、
/// 悬浮光点漂移、整卡呼吸透明度；状态切换时整卡动作跟着变化：
/// - idle（待机）：彩带慢速流动 + 光点漂浮 + 文字呼吸（卡片始终「��着」）
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

    private let cardHeight: CGFloat = 250
    private let firstUseDefaultsKey = "voiceAssistant.didShowFirstUseGuide"

    init(viewModel: VoiceAssistantViewModel, settingsStore: SettingsStore) {
        self.viewModel = viewModel
        self.settingsStore = settingsStore
    }

    var body: some View {
        ZStack {
            // 整卡流动彩带（Siri 风，四态共用一套背景，速度/亮度随状态变化）
            SiriBackgroundLayer(state: viewModel.state)
            // 悬浮光点（整卡漂浮）
            ParticleLayer()
            // 状态特效：聆听波纹扩散 / 思考旋转光点 / 播报整卡脉动
            StateEffectLayer(state: viewModel.state)

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
                settingsStore: settingsStore
            )
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speed = speedFactor
            // 整卡呼吸透明度（待机也有「活」感，0.82 ↔ 1.0）
            let breathing = 0.82 + 0.18 * abs(sin(t * 1.3))
            GeometryReader { geo in
                ZStack {
                    // 主色带：环形渐变绕中心旋转（Siri 绸缎流动感）
                    AngularGradient(
                        colors: [
                            Color(red: 0.62, green: 0.10, blue: 0.22),
                            Color(red: 0.50, green: 0.10, blue: 0.62),
                            Color(red: 0.08, green: 0.28, blue: 0.62),
                            Color(red: 0.62, green: 0.10, blue: 0.22)
                        ],
                        center: .center,
                        angle: .degrees(360 * (t * 0.05 * speed).truncatingRemainder(dividingBy: 1.0))
                    )
                    .blur(radius: 70)
                    .scaleEffect(1.25)

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
// MARK: - 悬浮光点（整卡漂浮）

private struct ParticleLayer: View {
    private let count = 14

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<count, id: \.self) { index in
                        let phase = Double(index) * 0.85
                        let x = geo.size.width * (0.10 + 0.80 * (Double(index % 5) / 4.0))
                            + CGFloat(12 * sin(t * 0.5 + phase))
                        let y = geo.size.height * (0.14 + 0.72 * (Double(index / 5) / 2.0))
                            + CGFloat(9 * cos(t * 0.6 + phase))
                        Circle()
                            .fill(.white.opacity(0.08 + 0.10 * abs(sin(t * 0.7 + phase))))
                            .frame(width: 3.5 + CGFloat(index % 3) * 1.5)
                            .position(x: x, y: y)
                    }
                    // 流星：两道细光轮流划过（Siri 标志性细节）
                    ForEach(0..<2, id: \.self) { index in
                        let phase = Double(index) * 0.5
                        let progress = (t * 0.12 + phase).truncatingRemainder(dividingBy: 1.0)
                        let x = geo.size.width * (progress * 1.35 - 0.18)
                        let y = geo.size.height * (0.18 + progress * 0.55)
                        Capsule()
                            .fill(.white.opacity(0.28 * (1 - progress)))
                            .frame(width: 46, height: 1.5)
                            .rotationEffect(.degrees(-35))
                            .position(x: x, y: y)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
// MARK: - 状态特效（聆听波纹 / 思考光点 / 播报脉动）

private struct StateEffectLayer: View {
    let state: VoiceAssistantState
    @State private var ripple = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch state {
                case .idle:
                    EmptyView()
                case .listening:
                    // 中央波纹扩散到整卡（Siri 听感）
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .stroke(Color.white.opacity(0.28), lineWidth: 1.5)
                            .frame(width: 60, height: 60)
                            .scaleEffect(ripple ? 1.0 + CGFloat(index + 1) * 2.8 : 1.0)
                            .opacity(ripple ? 0 : 0.55)
                            .animation(
                                .easeOut(duration: 2.0)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(index) * 0.6),
                                value: ripple
                            )
                    }
                case .thinking:
                    // 中央旋转光点
                    ThinkingOrbitView(color: .white, size: 84)
                case .speaking:
                    // 整卡快速脉动光罩
                    Circle()
                        .fill(.white.opacity(0.05))
                        .frame(width: geo.size.width * 0.92)
                        .blur(radius: 44)
                        .scaleEffect(ripple ? 1.12 : 0.9)
                        .opacity(ripple ? 0.10 : 0.03)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: ripple
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .onAppear { startRipple() }
        .onChange(of: state) { _, _ in
            // 状态切换时重开动画，避免旧动画延续
            ripple = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                startRipple()
            }
        }
    }

    private func startRipple() {
        withAnimation(.easeInOut(duration: 0.2)) {
            ripple = true
        }
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

// MARK: - 语音快捷设置（齿轮入口）

/// 语音大卡右上角齿轮弹出的快捷设置：对讲/唤醒开关 + 场景模式。
/// 完整的提供商/音色/语速音调/实时预览页由「方案1 语音设置入口」任务继续补齐。
struct VoiceAssistantQuickSettingsSheet: View {
    @Bindable var viewModel: VoiceAssistantViewModel
    @Bindable var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

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
}