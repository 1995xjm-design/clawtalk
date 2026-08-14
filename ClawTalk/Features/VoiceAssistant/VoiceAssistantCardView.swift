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
    // 错误横幅自动消失任务
    @State private var errorAutoClearTask: Task<Void, Never>?
    // 网关连接状态点：绿/红，点开显示原因（实时探测复用 DiagnosticsView 检测逻辑）
    @State private var gatewayProbeResult: VoiceAgentGatewayProbe.ProbeResult?
    @State private var isProbingGateway = false
    @State private var showGatewayStatus = false
    @State private var gatewayStatusMessage = ""

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
            // 主题动画层：5 套主题各自独立动画（极光多层光带/深海波浪下潜/落日暖色脉冲/森林条形起伏/暗夜星点呼吸）
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
            refreshGatewayProbeOnAppear()
        }
        .onDisappear {
            stopTipRotation()
            stopTextBreathing()
            errorAutoClearTask?.cancel()
            errorAutoClearTask = nil
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
        .onChange(of: viewModel.errorMessage) { _, newValue in
            guard newValue != nil else { return }
            errorAutoClearTask?.cancel()
            errorAutoClearTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    viewModel.clearErrorMessage()
                }
            }
        }
    }

    // MARK: - 中央内容（状态大字 + 提示/转写）

    private var contentOverlay: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            Text(statusText)
                .font(.system(.title1, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(viewModel.state == .idle ? (textBreathing ? 1.03 : 1.0) : 1.0)
                .opacity(viewModel.state == .idle ? (textBreathing ? 0.9 : 1.0) : 1.0)
                .shadow(color: .white.opacity(0.35), radius: 10)
                .contentTransition(.opacity)

            if showFirstUseGuide {
                Text("点按开始说话 · 长按退出")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .transition(.opacity)
            } else if viewModel.state == .idle {
                Text(currentTip)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .id("tip-\(tipIndex)")
                    .transition(.opacity.combined(with: .offset(y: 3)))
            } else {
                liveTextArea
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            if let intent = viewModel.pendingIntent {
                intentConfirmBar(intent)
            }

            if let feedback = viewModel.lastIntentFeedback {
                Text(feedback)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.85)))
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - 意图确认条（v049）

    /// 待确认意图确认条：显示「记一笔…对吗？」+ 确认/取消按钮，不阻塞正常对话。
    private func intentConfirmBar(_ intent: PendingVoiceIntent) -> some View {
        VStack(spacing: 6) {
            Text(intent.summary)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            HStack(spacing: 10) {
                Button {
                    viewModel.cancelPendingIntent()
                } label: {
                    Text("取消")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.22)))
                }
                .buttonStyle(.plain)
                Button {
                    viewModel.confirmPendingIntent()
                } label: {
                    Text("确认")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.blue.opacity(0.9)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.35)))
        .padding(.top, 6)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
                Haptics.warning()
            case .second:
                let willStart = viewModel.state == .idle
                viewModel.toggle()
                // 开始对讲中震动反馈，结束轻反馈。
                Haptics.impact(willStart ? .medium : .light)
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
                    Haptics.impact(.light)
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
            gatewayStatusDot
            if viewModel.isActive {
                Text("长按退出")
                    .font(.caption2.weight(.medium))
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
                    .font(.footnote.weight(.semibold))
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
                    .font(.footnote.weight(.semibold))
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
                    .font(.footnote.weight(.semibold))
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

    // MARK: - 网关连接状态点（绿/红，点开显示原因）

    /// 语音大卡左上角小连接状态点：绿=通道就绪（网关已配置且令牌有效 / DeepSeek Key 已配置），
    /// 红=缺少配置或探测失败；点按实时探测并弹出原因（复用 DiagnosticsView 检测逻辑）。
    private var gatewayStatusDot: some View {
        Button {
            presentGatewayStatus()
        } label: {
            HStack(spacing: 5) {
                if isProbingGateway {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Circle()
                        .fill(gatewayDotColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 1))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.28)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(gatewayDotAccessibilityText)
        .alert("网关连接状态", isPresented: $showGatewayStatus) {
            Button("好", role: .cancel) {}
        } message: {
            Text(gatewayStatusMessage)
        }
    }

    private var gatewayDotColor: Color {
        if isProbingGateway { return .white.opacity(0.9) }
        if let result = gatewayProbeResult {
            return result.success ? .green : .red
        }
        return gatewayChannelConfigured ? .green : .red
    }

    /// 通道是否已就绪（网关模式：网关地址 + 令牌齐全；直连 DeepSeek：API Key 已配置）。
    private var gatewayChannelConfigured: Bool {
        switch settingsStore.settings.voiceAgentChannel {
        case .directDeepSeek:
            return !(SecureStorage.shared.getString("deepseek_api_key") ?? "").isEmpty
        case .gateway:
            let urlConfigured = !settingsStore.settings.gatewayURL
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let token = OpenClawClient.resolveHTTPToken(
                settingsToken: settingsStore.gatewayToken,
                gatewayURL: settingsStore.settings.gatewayURL
            )
            return urlConfigured && !token.isEmpty
        }
    }

    private var gatewayDotAccessibilityText: String {
        switch settingsStore.settings.voiceAgentChannel {
        case .directDeepSeek:
            return "语音助手通道：直连 DeepSeek"
        case .gateway:
            return gatewayChannelConfigured ? "网关连接已配置" : "网关未配置或令牌缺失"
        }
    }

    private func presentGatewayStatus() {
        switch settingsStore.settings.voiceAgentChannel {
        case .directDeepSeek:
            let hasKey = !(SecureStorage.shared.getString("deepseek_api_key") ?? "").isEmpty
            gatewayStatusMessage = hasKey
                ? "通道：直连 DeepSeek\nAPI Key：已配置"
                : "通道：直连 DeepSeek\nAPI Key：未配置（请到 设置 > 语音助手通道 填写）"
            showGatewayStatus = true
        case .gateway:
            guard !isProbingGateway else { return }
            refreshGatewayProbe(showResult: true)
        }
    }

    /// 首次出现时静默探测一次，让圆点显示真实连接状态；之后再点按手动刷新。
    private func refreshGatewayProbeOnAppear() {
        guard settingsStore.settings.voiceAgentChannel == .gateway, gatewayProbeResult == nil else { return }
        refreshGatewayProbe(showResult: false)
    }

    private func refreshGatewayProbe(showResult: Bool) {
        guard !isProbingGateway else { return }
        isProbingGateway = true
        Task { @MainActor in
            let result = await VoiceAgentGatewayProbe.run(settings: settingsStore)
            isProbingGateway = false
            gatewayProbeResult = result
            if showResult {
                gatewayStatusMessage = gatewayStatusMessage(for: result)
                showGatewayStatus = true
            }
        }
    }

    private func gatewayStatusMessage(for result: VoiceAgentGatewayProbe.ProbeResult) -> String {
        let url = settingsStore.settings.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = OpenClawClient.resolveHTTPToken(
            settingsToken: settingsStore.gatewayToken,
            gatewayURL: settingsStore.settings.gatewayURL
        )
        var lines: [String] = []
        lines.append(url.isEmpty ? "网关地址：未配置" : "网关地址：\(url)")
        lines.append(token.isEmpty ? "网关令牌：未获取到" : "网关令牌：已设置")
        lines.append("探测结果：\(result.message)")
        return lines.joined(separator: "\n")
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
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .id("transcript")
                    .transition(.opacity.combined(with: .offset(y: 4)))
            case .speaking:
                Text(viewModel.lastReply)
                    .font(.caption)
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
// MARK: - 沉浸式动画体系（参考图重构：深蓝紫背景 + 中央核心 + 四周光效 + 底部弧形 + 顶部光带）

/// 沉浸背景：深蓝紫渐变（模拟参考图深色沉浸氛围），叠加主题强调色光晕与暗角，整卡呼吸。
private struct SiriBackgroundLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 整卡呼吸透明度（待机也有「活」感）
            let breathing = 0.84 + 0.16 * abs(sin(t * 1.2))
            GeometryReader { geo in
                ZStack {
                    // 深蓝紫沉浸渐变底（参考图氛围）
                    LinearGradient(
                        colors: theme.backgroundColors,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // 中央光晕（主题强调色，呼吸）
                    RadialGradient(
                        colors: [theme.accentColor.opacity(0.28 * breathing), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: geo.size.width * 0.78
                    )
                    .blur(radius: 28)
                    // 边缘暗角（层次感）
                    RadialGradient(
                        colors: [.clear, .black.opacity(0.42)],
                        center: .center,
                        startRadius: geo.size.width * 0.45,
                        endRadius: max(geo.size.width, geo.size.height) * 0.8
                    )
                }
                .opacity(breathing)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 主题动画层（线J：5 套主题独立动画实现）

/// 主题动画层：按 `theme.waveform` 分发到 5 套完全独立的动画实现——
/// 极光（多层流动光带）/ 深海（波浪下潜）/ 落日（暖色脉冲）/ 森林（条形起伏）/ 暗夜（星点呼吸）。
/// 每套都随真实麦克风音量（audioLevel）起伏，待机低幅微澜；对话/录音/设置逻辑不受影响。
private struct ThemeAnimationLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    @ViewBuilder
    var body: some View {
        switch theme.waveform {
        case .auroraBands:
            AuroraFlowLayer(state: state, theme: theme, micLevel: micLevel, micActive: micActive)
        case .oceanDive:
            OceanDiveLayer(state: state, theme: theme, micLevel: micLevel, micActive: micActive)
        case .sunsetPulse:
            SunsetPulseLayer(state: state, theme: theme, micLevel: micLevel, micActive: micActive)
        case .forestBars:
            ForestBarLayer(state: state, theme: theme, micLevel: micLevel, micActive: micActive)
        case .stardust:
            StardustLayer(state: state, theme: theme, micLevel: micLevel, micActive: micActive)
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

// MARK: - 线J：5 套主题独立动画实现（每套波形形态/动效/光效完全不同）

/// 状态动画倍速：待机最慢，聆听/播报加速。
private func stateSpeedMultiplier(_ state: VoiceAssistantState) -> Double {
    switch state {
    case .idle: return 1.0
    case .listening: return 1.9
    case .thinking: return 1.25
    case .speaking: return 2.4
    }
}

/// 状态亮度系数：待机偏暗（低打扰），聆听/播报最亮。
private func stateBrightnessMultiplier(_ state: VoiceAssistantState) -> Double {
    switch state {
    case .idle: return 0.55
    case .listening: return 1.0
    case .thinking: return 0.75
    case .speaking: return 1.0
    }
}

// MARK: - 主题 1/5 极光：多层流动光带

/// 极光主题动画：3 条不同相位/速度的水平光带上下游走 + 沿带白色高光扫动，像多层极光帘。
/// 音量越大：光带越亮、起伏越高、扫动越快；待机低幅漂移微澜。
private struct AuroraFlowLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    private let bandCount = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: 0.3)
                ZStack {
                    ForEach(0..<bandCount, id: \.self) { index in
                        auroraBand(index: index, width: width, height: height, t: t, amp: amp)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func auroraBand(index: Int, width: CGFloat, height: CGFloat, t: TimeInterval, amp: Double) -> some View {
        let speed = stateSpeedMultiplier(state) * theme.idleSpeed * (0.75 + 0.20 * Double(index))
        let phase = Double(index) * 1.9
        let baseY = height * (0.16 + 0.15 * CGFloat(index))
        let waveHeight = (4.0 + amp * 13.0) * (1.0 - 0.16 * Double(index))
        let waveFreq = 1.6 + 0.4 * Double(index)
        let driftY = CGFloat(amp * 9.0 * sin(t * 0.8 + phase))
        let y = baseY + driftY
        let sweep = (t * speed * 0.10 + Double(index) * 0.37).truncatingRemainder(dividingBy: 1.0)
        let bright = stateBrightnessMultiplier(state)
        let colors = theme.ribbonColors.map { $0.opacity((0.45 + 0.55 * amp) * bright) }
        return ZStack {
            // 光带本体（正弦起伏曲线）
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                for step in 0...22 {
                    let x = width * CGFloat(step) / 22.0
                    let yy = y + CGFloat(waveHeight) * CGFloat(sin(t * waveFreq + Double(step) * 0.30 + phase))
                    path.addLine(to: CGPoint(x: x, y: yy))
                }
            }
            .stroke(
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: 2.4 + amp * 2.2, lineCap: .round)
            )
            .blur(radius: 1.5)
            .shadow(color: theme.accentColor.opacity(0.5), radius: 10)

            // 沿光带流动的白色高光
            let fx = width * CGFloat(sweep)
            let fy = y + CGFloat(waveHeight) * CGFloat(sin(t * waveFreq + sweep * 6.8 + phase))
            Circle()
                .fill(.white.opacity((0.30 + 0.60 * amp) * bright))
                .frame(width: 9 + amp * 7, height: 9 + amp * 7)
                .blur(radius: 3.5)
                .position(x: fx, y: fy)
        }
    }
}

// MARK: - 主题 2/5 深海：波浪下潜

/// 深海主题动画：重叠正弦波（水面/中层/深层）随音量整体下潜 + 上升气泡。
/// 音量越大：波浪下潜更深、波幅越大、气泡越亮；待机水面轻伏。
private struct OceanDiveLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    private let waveCount = 3
    private let bubbleCount = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: 0.7)
                ZStack {
                    ForEach(0..<waveCount, id: \.self) { index in
                        oceanWave(index: index, width: width, height: height, t: t, amp: amp)
                    }
                    ForEach(0..<bubbleCount, id: \.self) { index in
                        oceanBubble(index: index, width: width, height: height, t: t, amp: amp)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func oceanWave(index: Int, width: CGFloat, height: CGFloat, t: TimeInterval, amp: Double) -> some View {
        let speed = stateSpeedMultiplier(state) * theme.idleSpeed
        let phase = Double(index) * 1.3
        // 下潜深度：音量越大越深
        let dive = CGFloat(amp * 26.0)
        let baseY = height * (0.30 + 0.18 * CGFloat(index)) + dive
        let waveHeight = (3.0 + amp * 11.0) * (1.0 - 0.12 * Double(index))
        let waveFreq = 2.0 + 0.5 * Double(index)
        let bright = stateBrightnessMultiplier(state)
        let colors = [
            theme.accentColor.opacity(0.14 * bright),
            theme.accentColor.opacity((0.50 + 0.40 * amp) * bright),
            theme.accentColor.opacity(0.14 * bright)
        ]
        return Path { path in
            path.move(to: CGPoint(x: 0, y: baseY))
            for step in 0...26 {
                let x = width * CGFloat(step) / 26.0
                let yy = baseY + CGFloat(waveHeight) * CGFloat(sin(t * speed * 0.9 + Double(step) * 0.36 + phase))
                path.addLine(to: CGPoint(x: x, y: yy))
            }
        }
        .stroke(
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
            style: StrokeStyle(lineWidth: 2.0 + amp * 2.0, lineCap: .round)
        )
        .blur(radius: 1.2)
        .shadow(color: theme.accentColor.opacity(0.4), radius: 7)
    }

    private func oceanBubble(index: Int, width: CGFloat, height: CGFloat, t: TimeInterval, amp: Double) -> some View {
        let speed = stateSpeedMultiplier(state) * (0.9 + 0.25 * Double(index % 4))
        let seed = Double(index) * 2.3999
        let x = width * CGFloat(0.08 + 0.84 * (seed * 0.618).truncatingRemainder(dividingBy: 1.0))
        let cycle = (t * speed * 0.10 + seed * 0.13).truncatingRemainder(dividingBy: 1.0)
        let y = height * (0.78 - 0.62 * CGFloat(cycle))
        let twinkle = 0.4 + 0.6 * abs(sin(t * 1.6 + seed))
        let bright = stateBrightnessMultiplier(state)
        let size = 2.0 + CGFloat(index % 3) * 1.6 + amp * 2.5
        return Circle()
            .fill(.white.opacity(0.16 * twinkle * (0.4 + 0.6 * amp) * bright))
            .frame(width: size, height: size)
            .blur(radius: 0.6)
            .position(x: x, y: y)
    }
}

// MARK: - 主题 3/5 落日：暖色脉冲

/// 落日主题动画：底部暖色「落日」光球呼吸 + 3 圈暖色圆环向外扩散（波纹）。
/// 音量越大：光球越亮越大、圆环扩散越快越明显；待机缓慢暖光脉动。
private struct SunsetPulseLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    private let ringCount = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: 0.2)
                let speed = stateSpeedMultiplier(state) * theme.idleSpeed
                let center = CGPoint(x: width * 0.5, y: height * 0.66)
                let breathe = 0.5 + 0.5 * abs(sin(t * 1.2))
                let bright = stateBrightnessMultiplier(state)
                ZStack {
                    // 落日光球（暖色呼吸 + 随音量变大）
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    theme.accentColor.opacity((0.55 + 0.45 * amp) * bright),
                                    theme.accentColor.opacity(0.25 * breathe * bright),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: width * 0.30
                            )
                        )
                        .frame(width: width * 0.62, height: width * 0.62)
                        .blur(radius: 6)
                        .position(center)
                        .scaleEffect(1.0 + amp * 0.10)

                    // 暖色扩散圆环（3 圈错相）
                    ForEach(0..<ringCount, id: \.self) { index in
                        let progress = (t * speed * (0.30 + 0.35 * amp) + Double(index) / Double(ringCount))
                            .truncatingRemainder(dividingBy: 1.0)
                        let radius = width * 0.16 * CGFloat(progress)
                        let opacity = (1.0 - progress) * (0.16 + 0.40 * amp) * bright
                        Circle()
                            .stroke(
                                theme.accentColor.opacity(opacity),
                                lineWidth: progress < 0.2 ? 2.2 : 1.2
                            )
                            .frame(width: radius * 2, height: radius * 2)
                            .position(center)
                            .blur(radius: 0.8)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 主题 4/5 森林：条形起伏

/// 森林主题动画：底部近远两排竖直条形（近亮远暗）如树冠随风起伏。
/// 音量越大：条高越高、摆动越快；待机树冠轻摆微澜。
private struct ForestBarLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    private let barCount = 23

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: 0.5)
                let speed = stateSpeedMultiplier(state) * theme.idleSpeed
                ZStack {
                    // 远景条（暗、矮）
                    barRow(back: true, width: width, height: height, t: t, amp: amp, speed: speed)
                    // 近景条（亮、高）
                    barRow(back: false, width: width, height: height, t: t, amp: amp, speed: speed)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func barRow(back: Bool, width: CGFloat, height: CGFloat, t: TimeInterval, amp: Double, speed: Double) -> some View {
        let spacing = width / CGFloat(barCount + 1)
        let baseHeight = back ? height * 0.10 : height * 0.16
        let topY = back ? height * 0.78 : height * 0.80
        let maxRise = back ? height * 0.10 : height * 0.20
        let phaseOffset = back ? 1.3 : 0.0
        let bright = stateBrightnessMultiplier(state)
        return ZStack {
            ForEach(0..<barCount, id: \.self) { index in
                let phase = Double(index) * 0.28 + phaseOffset
                let sway = 0.30 + 0.70 * abs(sin(t * speed * 1.2 + phase))
                let barHeight = baseHeight + maxRise * CGFloat(sway) * CGFloat(0.35 + 0.65 * amp)
                let x = spacing * CGFloat(index + 1)
                let y = topY - barHeight
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: back
                                ? [theme.accentColor.opacity(0.18), theme.accentColor.opacity(0.05)]
                                : [
                                    theme.accentColor.opacity((0.70 + 0.30 * amp) * bright),
                                    theme.accentColor.opacity(0.12)
                                ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: back ? 3.4 : 4.6, height: barHeight)
                    .position(x: x, y: y)
                    .shadow(color: back ? .clear : theme.accentColor.opacity(0.35), radius: 4)
            }
        }
    }
}

// MARK: - 主题 5/5 暗夜：星点呼吸

/// 暗夜主题动画：稀疏星点按各自相位呼吸（大小/亮度同步起伏）+ 中央微光。
/// 音量越大：星点越亮越大、呼吸加快；待机缓慢呼吸（几乎不动）。
private struct StardustLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    private let starCount = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: 0.4)
                let speed = stateSpeedMultiplier(state) * theme.idleSpeed
                let breathe = 0.5 + 0.5 * abs(sin(t * 1.0))
                let bright = stateBrightnessMultiplier(state)
                ZStack {
                    // 中央微光（星云感，暗夜主题低亮度）
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.10 * breathe * (0.3 + 0.7 * amp) * bright), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: width * 0.34
                            )
                        )
                        .frame(width: width * 0.68, height: width * 0.68)
                        .blur(radius: 10)
                        .position(x: width * 0.5, y: height * 0.46)

                    ForEach(0..<starCount, id: \.self) { index in
                        star(index: index, width: width, height: height, t: t, amp: amp, speed: speed)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func star(index: Int, width: CGFloat, height: CGFloat, t: TimeInterval, amp: Double, speed: Double) -> some View {
        let seed = Double(index) * 2.3999
        let x = width * CGFloat(0.05 + 0.90 * (seed * 0.618).truncatingRemainder(dividingBy: 1.0))
        let y = height * CGFloat(0.10 + 0.80 * (seed * 0.314).truncatingRemainder(dividingBy: 1.0))
        let phase = seed * 2.0
        let breathe = 0.5 + 0.5 * sin(t * speed * 0.7 + phase)
        let brightness = (0.15 + 0.50 * breathe) * (0.30 + 0.70 * amp)
        let size = 1.6 + CGFloat(index % 3) * 1.5 + CGFloat(breathe) * 2.0
        return Circle()
            .fill(.white.opacity(brightness))
            .frame(width: size, height: size)
            .blur(radius: index % 4 == 0 ? 1.2 : 0.4)
            .position(x: x, y: y)
    }
}

// MARK: - 历史动画组件（线J 起保留：功能零删除约束；主题分发已切换为上方 5 套独立实现）
// MARK: - 中央核心：圆形排布音量条 + 中心光球

/// 参考图核心视觉：16 根小竖条等角围绕圆心（波形球/声波），中心光球呼吸；
/// idle 微澜、listening 随真实音量、thinking 均匀脉冲、speaking 随播报节奏。
private struct OrbCoreView: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    private let barCount = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let centerX = geo.size.width / 2
                let centerY = geo.size.height * 0.46
                let radius = min(geo.size.width, geo.size.height) * 0.16
                let glow = coreGlow(t: t)
                ZStack {
                    // 中心光球（呼吸 + 随音量）
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white.opacity(0.75 * glow),
                                    theme.accentColor.opacity(0.5 * glow),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: radius * 0.95
                            )
                        )
                        .frame(width: radius * 1.7, height: radius * 1.7)
                        .blur(radius: 5)
                        .position(x: centerX, y: centerY)

                    // 环形音量条（围绕中心等角排列）
                    ForEach(0..<barCount, id: \.self) { index in
                        let angle = Double(index) / Double(barCount) * 360
                        let level = orbLevel(index: index, t: t)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.accentColor.opacity(0.95),
                                        .white.opacity(0.9)
                                    ],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(width: 2.6, height: max(4, radius * 0.62 * level))
                            .offset(y: -radius * 1.12)
                            .rotationEffect(.degrees(angle))
                            .position(x: centerX, y: centerY)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 中心光球强度：随状态变化。
    private func coreGlow(t: TimeInterval) -> Double {
        switch state {
        case .idle:
            return 0.60 + 0.16 * abs(sin(t * 1.1))
        case .listening:
            return 0.66 + 0.30 * Double(min(micLevel * 5.0, 1.0))
        case .thinking:
            return 0.64 + 0.22 * abs(sin(t * 3.2))
        case .speaking:
            return 0.70 + 0.28 * abs(sin(t * 2.4))
        }
    }

    /// 单根环绕条高度：随状态与音量。
    private func orbLevel(index: Int, t: TimeInterval) -> Double {
        let phase = Double(index) * 0.42
        switch state {
        case .idle:
            let sweep = abs(sin(t * 1.0 + phase))
            return max(0.10, theme.idleAmplitude * (0.35 + 0.65 * sweep) * 1.3)
        case .listening:
            if micActive {
                let amp = Double(min(micLevel * 6.0, 1.0))
                let wobble = 0.55 + 0.45 * abs(sin(t * 3.0 + phase))
                return max(0.12, min(1.0, amp * 1.2 * wobble + 0.08))
            }
            return 0.32 + 0.24 * abs(sin(t * 2.2 + phase))
        case .thinking:
            return 0.30 + 0.28 * abs(sin(t * 2.6 + phase))
        case .speaking:
            let beat = 0.5 + 0.5 * abs(sin(t * 2.0 + phase * 0.7))
            return max(0.15, 0.20 + 0.80 * beat)
        }
    }
}

// MARK: - 四周动态光效：圆环扩散 + 漂浮光点

private struct HaloLayer: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme

    private let particleCount = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let centerX = geo.size.width / 2
                let centerY = geo.size.height * 0.46
                let maxRadius = geo.size.height * 0.40
                let speed = rippleSpeed
                ZStack {
                    // 圆环扩散（2 圈错相）
                    ForEach(0..<2, id: \.self) { index in
                        let progress = (t * speed + Double(index) * 0.5).truncatingRemainder(dividingBy: 1.0)
                        let radius = maxRadius * progress
                        let opacity = (1.0 - progress) * (state == .idle ? 0.20 : 0.34)
                        Circle()
                            .stroke(theme.accentColor.opacity(opacity), lineWidth: progress < 0.18 ? 1.8 : 1.0)
                            .frame(width: radius * 2, height: radius * 2)
                            .position(x: centerX, y: centerY)
                    }
                    // 漂浮光点（绕核心椭圆轨道漂移）
                    ForEach(0..<particleCount, id: \.self) { index in
                        let phase = Double(index) * 1.31
                        let orbit = 0.18 + 0.08 * Double(index % 3)
                        let angle = t * theme.idleSpeed * 0.18 + phase
                        let radius = min(geo.size.width, geo.size.height) * orbit
                        let x = centerX + cos(angle) * radius
                        let y = centerY + sin(angle) * radius * 0.8
                        let twinkle = 0.5 + 0.5 * sin(t * 1.8 + phase)
                        Circle()
                            .fill(.white.opacity(theme.particleOpacity * (0.18 + 0.30 * twinkle)))
                            .frame(width: 2.2 + CGFloat(index % 3) * 1.2, height: 2.2 + CGFloat(index % 3) * 1.2)
                            .position(x: x, y: y)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 圆环扩散速度：待机缓慢，对讲加速。
    private var rippleSpeed: Double {
        switch state {
        case .idle: return 0.30
        case .listening: return 0.55
        case .thinking: return 0.42
        case .speaking: return 0.80
        }
    }
}

// MARK: - 底部弧形光带（渐变弧线，随音量起伏 + 流动高光）

private struct BottomArcGlow: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme
    let micLevel: Float
    let micActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let yBase = height * 0.82
                let amp = ambientLevel(state: state, theme: theme, micLevel: micLevel, micActive: micActive, t: t, phase: 0.5)
                let controlY = yBase - (6.0 + amp * 14.0)
                let glow = 0.30 + 0.70 * amp
                ZStack {
                    // 渐变弧形主光带
                    Path { path in
                        path.move(to: CGPoint(x: width * 0.12, y: yBase))
                        path.addQuadCurve(
                            to: CGPoint(x: width * 0.88, y: yBase),
                            control: CGPoint(x: width * 0.5, y: controlY)
                        )
                    }
                    .stroke(
                        LinearGradient(
                            colors: [
                                .clear,
                                theme.accentColor.opacity(0.85 * glow),
                                .white.opacity(0.9 * glow),
                                theme.accentColor.opacity(0.85 * glow),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 3.0 + amp * 3.0, lineCap: .round)
                    )
                    .blur(radius: 1.5)
                    .shadow(color: theme.accentColor.opacity(0.5 * glow), radius: 8)

                    // 沿弧流动高光（二次贝塞尔插值）
                    let flow = (t * theme.idleSpeed * 0.5).truncatingRemainder(dividingBy: 1.0)
                    let fx = width * 0.12 + width * 0.76 * flow
                    let q = Double(flow)
                    let fy = (1 - q) * (1 - q) * yBase + 2 * q * (1 - q) * controlY + q * q * yBase
                    Circle()
                        .fill(.white.opacity(0.95 * glow))
                        .frame(width: 7 + amp * 5, height: 7 + amp * 5)
                        .blur(radius: 3)
                        .position(x: fx, y: fy)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 顶部光带（水平流动渐变，蓝→紫→青）

private struct TopLightBand: View {
    let state: VoiceAssistantState
    let theme: VoiceAssistantTheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let bandWidth = geo.size.width * 0.60
                let flow = (t * theme.idleSpeed * 0.4).truncatingRemainder(dividingBy: 1.0)
                let offset = (flow * 2.0 - 1.0) * bandWidth * 0.18
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                AppTokens.voiceAuraBlue.opacity(0.6),
                                AppTokens.voiceAuraPurple.opacity(0.6),
                                AppTokens.voiceAuraCyan.opacity(0.6),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: bandWidth, height: 3.0 + (state == .idle ? 0 : 2.0))
                    .blur(radius: 1)
                    .shadow(color: AppTokens.voiceAuraBlueShadow.opacity(0.6), radius: 6)
                    .position(x: geo.size.width / 2 + offset, y: 14)
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
