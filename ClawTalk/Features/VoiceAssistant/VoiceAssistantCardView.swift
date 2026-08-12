import SwiftUI
import UIKit

/// 随身语音助手主卡片：点按开始/结束连续对讲，长按退出。
///
/// 新设计（明哥拍板）：去掉中央麦克风按钮，以「状态大字 + 底部音波带」为主视觉。
/// 四种状态统一由底部音波带呈现（同一组竖条连续变形，不跳变）：
/// - idle（待机）：音波带正弦微澜 + 背景光斑缓慢流动 + 提示文字轮播 —— 卡片常驻「活」感
/// - listening（聆听中）：音波跟随实时输入音量跳动
/// - thinking（思考中）：光带从左到右扫过（扫描感）+ 微呼吸
/// - speaking（播报中）：声波跳动，叠加实时音量
///
/// 说明：卡片自身不再绘制渐变底/描边（由 VoiceAssistantCardSlot 统一提供），
/// 本视图只负责内容层 + 状态动画 + 点按反馈 + 顶部操作栏。
struct VoiceAssistantCardView: View, VoiceAssistantCardContent {
    @Bindable var viewModel: VoiceAssistantViewModel
    /// 语音快捷设置（齿轮）数据源
    @Bindable var settingsStore: SettingsStore

    // 首次使用引导是否显示
    @State private var showFirstUseGuide = false
    // 实时转写逐字冒出：已显示字符数 + 当前逐字显示的原文（同段文字不重复重播）
    @State private var revealedTranscriptCount = 0
    @State private var revealedTranscriptText = ""
    @State private var transcriptRevealTask: Task<Void, Never>?
    // 点按反馈：按下收缩 / 松手回弹
    @State private var pressed = false
    @State private var pressStart: Date?
    // 待机提示轮播
    @State private var tipIndex = 0
    @State private var tipTask: Task<Void, Never>?
    // 齿轮 → 语音快捷设置
    @State private var showQuickSettings = false

    private let cardHeight: CGFloat = 240
    private let firstUseDefaultsKey = "voiceAssistant.didShowFirstUseGuide"

    init(viewModel: VoiceAssistantViewModel, settingsStore: SettingsStore) {
        self.viewModel = viewModel
        self.settingsStore = settingsStore
    }

    var body: some View {
        ZStack {
            // A. 常驻灵动：缓慢流动的光斑（呼吸灯），待机也在「呼吸」
            ambientLayer

            VStack(spacing: 6) {
                Spacer(minLength: 0)

                // 状态大字（主视觉，无按钮遮挡）
                Text(statusText)
                    .font(.system(size: 26.0 * sceneFontScale, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)

                // 首次引导 / 待机提示轮播 / 实时转写与回复
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

                // 底部音波带（主角）
                waveBand
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
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
        }
        .onDisappear {
            stopTipRotation()
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

    /// B. 跟手反馈：按下瞬间卡片轻微收缩 + 轻触觉；开始滚动/松手时回弹。
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

    // MARK: - A. 常驻灵动：流动光斑（呼吸灯）

    @ViewBuilder
    private var ambientLayer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 220, height: 220)
                    .blur(radius: 46)
                    .offset(x: CGFloat(72 * sin(time * 0.35)), y: CGFloat(36 * cos(time * 0.5)))
                Circle()
                    .fill(Color.openClawDarkRed.opacity(0.38))
                    .frame(width: 180, height: 180)
                    .blur(radius: 34)
                    .offset(x: CGFloat(-58 * cos(time * 0.28)), y: CGFloat(32 * sin(time * 0.44)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    // MARK: - 底部音波带（主视觉，四种状态同一组竖条连续变形）

    private var waveBand: some View {
        VoiceWaveBandView(state: viewModel.state, level: viewModel.audioLevel)
            .frame(height: 72)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.black.opacity(0.14))
            )
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

    // MARK: - 待机提示轮播

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

// MARK: - 底部音波带：同一组竖条，四种状态连续变形（C. 状态连贯）

private struct VoiceWaveBandView: View {
    let state: VoiceAssistantState
    let level: Float

    private let barCount = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(barOpacity(at: time, index: index)))
                        .frame(width: 4, height: barHeight(at: time, index: index))
                        .animation(.easeInOut(duration: 0.3), value: state)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 竖条高度：idle 微澜 → listening 实时音量 → thinking 扫描光带 → speaking 声波跳动。
    private func barHeight(at time: TimeInterval, index: Int) -> CGFloat {
        let phase = Double(index) * 0.5
        let levelBoost = CGFloat(min(max(level, 0), 1))
        switch state {
        case .idle:
            let wave = abs(sin(time * 1.8 + phase * 0.4))
            return 6 + wave * 22
        case .listening:
            let wave = abs(sin(time * 3.2 + phase))
            return 10 + wave * 34 + levelBoost * 30
        case .thinking:
            let sweep = (time * 2.2).truncatingRemainder(dividingBy: Double(barCount))
            let pulse = exp(-abs(Double(index) - sweep) * 0.55)
            return 8 + pulse * 42 + 6 * abs(sin(time * 1.4 + phase * 0.3))
        case .speaking:
            let wave = abs(sin(time * 2.8 + phase))
            return 10 + wave * 40 + levelBoost * 24
        }
    }

    private func barOpacity(at time: TimeInterval, index: Int) -> Double {
        let phase = Double(index) * 0.5
        switch state {
        case .idle:
            return 0.32 + 0.16 * abs(sin(time * 1.6 + phase * 0.3))
        case .listening:
            return 0.66 + 0.34 * abs(sin(time * 3.2 + phase))
        case .thinking:
            return 0.5 + 0.3 * abs(sin(time * 2.0 + phase * 0.4))
        case .speaking:
            return 0.6 + 0.4 * abs(sin(time * 2.8 + phase))
        }
    }
}

// MARK: - 语音快捷设置（齿轮入口，方案1 第一步）

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