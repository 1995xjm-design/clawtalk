import SwiftUI
import AVFoundation
import Combine
import UIKit
import UserNotifications
import WidgetKit

@main
struct ClawTalkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsStore: SettingsStore
    @State private var channelStore: ChannelStore
    @State private var selectedChannel: Channel?
    @State private var chatViewModel: ChatViewModel?
    @State private var syncChatViewModel: SyncChatViewModel?
    @State private var selectedSyncChannel: Channel?
    @State private var backgroundViewModels: [UUID: ChatViewModel] = [:]
    @State private var voiceWakeWatchdogTask: Task<Void, Never>?
    @State private var gatewayConnection = GatewayConnection()
    @State private var nodeConnection = NodeConnection()
    @State private var ackSynthesizer: AVSpeechSynthesizer?
    @State private var showGatewaySessions = false
    @State private var showHomeTools = false
    @State private var showKeyboardSettings = false
    @State private var gatewaySessionsViewModel: ToolsViewModel?
    @State private var widgetSnapshot: WidgetSnapshot?
    @State private var syncedChannelsSignature: String?
    @State private var selectedTab = 1
    @State private var activeChatRoute: ChatRoute?

    private enum ChatRoute: Hashable {
        case chat
        case sync
        case fileTransfer
    }

    init() {
        #if DEBUG
        DemoDataSeeder.seedIfNeeded()
        #endif
        _settingsStore = State(initialValue: SettingsStore())
        _channelStore = State(initialValue: ChannelStore.shared)
    }

    // MARK: - 主界面 ZStack（拆出独立计算属性，避免 SwiftUI 类型检查超时）

    @ViewBuilder
    private var mainZStack: some View {
        NavigationStack {
            ZStack {
                ChannelListView(
                    channelStore: channelStore,
                    settingsStore: settingsStore,
                    gatewayConnection: gatewayConnection,
                    nodeConnection: nodeConnection,
                    onSelect: { channel in
                        selectChannel(channel)
                    },
                    onSelectFileTransfer: { activeChatRoute = .fileTransfer },
                    onOpenGatewaySessions: { openGatewaySessionsList() }
                )
            }
            .navigationDestination(item: $activeChatRoute) { route in
                chatDestination(route)
            }
            .onChange(of: activeChatRoute) { oldValue, newValue in
                // 系统侧滑返回 / 自绘返回按钮：路由清空时做聊天页退出清理
                if oldValue != nil && newValue == nil {
                    handleChatRouteCleared()
                }
            }
        }
    }

    /// 聊天页路由目标（NavigationStack push，获得系统原生侧滑返回手势）。
    @ViewBuilder
    private func chatDestination(_ route: ChatRoute) -> some View {
        switch route {
        case .chat:
            if let vm = chatViewModel, selectedChannel != nil {
                ChatView(
                    viewModel: vm,
                    settingsStore: settingsStore,
                    gatewayConnection: gatewayConnection,
                    onBack: goBack,
                    onDeleteChannel: deleteCurrentChannel
                )
                .toolbar(.hidden, for: .navigationBar)
                .background(EnableSwipeBack())
                .onChange(of: vm.isConversationMode) { _, isOn in
                    if isOn {
                        stopVoiceWake()
                    } else {
                        startVoiceWakeIfNeeded()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .clawTalkWakeRestartRequested)) { _ in
                    startVoiceWakeIfNeeded()
                }
            }
        case .sync:
            if let syncVM = syncChatViewModel, selectedSyncChannel != nil {
                SyncChatView(viewModel: syncVM, onBack: goBack, onDeleteChannel: deleteCurrentChannel)
                    .toolbar(.hidden, for: .navigationBar)
                    .background(EnableSwipeBack())
            }
        case .fileTransfer:
            FileTransferChannelView(settings: settingsStore, onBack: goBack)
                .toolbar(.hidden, for: .navigationBar)
                .background(EnableSwipeBack())
        }
    }
    // MARK: - 主界面 TabView（频道列表 + 主页 Tab）

    @ViewBuilder
    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            mainZStack
                .toolbar(isChatPresented ? .hidden : .visible, for: .tabBar)
                .tabItem {
                    Label(String(localized: "Channels"), systemImage: "message.fill")
                }
                .tag(0)

            HomeTabView(
                settings: settingsStore,
                gatewayConnection: gatewayConnection,
                chatViewModel: chatViewModel,
                onOpenTools: { showHomeTools = true }
            )
            .sheet(isPresented: $showHomeTools) {
                ToolsView(settings: settingsStore, gatewayConnection: gatewayConnection, nodeConnection: nodeConnection)
            }
            .tabItem {
                Label(String(localized: "Home"), systemImage: "square.grid.2x2")
            }
            .tag(1)
        }
        .onReceive(NotificationCenter.default.publisher(for: LogCollector.autoUploadNotification)) { _ in
            uploadLogsAutomatically()
        }
    }

    /// C1：日志累 20 条自动发电脑 inbound（手动发送保留在日志诊断页）。
    private func uploadLogsAutomatically() {
        let text = LogCollector.exportText()
        guard !text.isEmpty else {
            LogCollector.resetPendingUploadCount()
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "clawtalk-logs-auto-\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            LogCollector.resetPendingUploadCount()
            return
        }
        Task {
            let ok = await FileTransferViewModel(settings: settingsStore).uploadFile(fileURL: url, suggestedName: name)
            LogCollector.resetPendingUploadCount()
            if !ok {
                LogCollector.record(module: "日志上报", "自动上传日志失败：\(name)")
            }
        }
    }

    /// 聊天 / 同步聊天 / 文件传输覆盖层打开时隐藏 Tab 栏，保持全屏聊天体验。
    private var isChatPresented: Bool {
        activeChatRoute != nil
    }

    var body: some Scene {
        WindowGroup {
            windowContent
        }
    }

    /// 根内容：引导页 / 主界面切换 + 深链接入口（拆出独立计算属性，避免类型检查超时）。
    @ViewBuilder
    private var rootWindowContent: some View {
        Group {
            if !settingsStore.hasCompletedOnboarding {
                OnboardingView(settingsStore: settingsStore) {
                    // Onboarding complete
                }
            } else {
                mainTabView
            }
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
    }

    /// WindowGroup 内容（拆出独立计算属性，避免 SwiftUI 类型检查超时）
    @ViewBuilder
    private var windowContent: some View {
        rootWindowContent
            .overlay {
                ApprovalOverlayView(gatewayConnection: gatewayConnection)
            }
            .sheet(isPresented: Binding(
                get: { CanvasCapability.shared.isPresented },
                set: { CanvasCapability.shared.isPresented = $0 }
            )) {
                CanvasView(canvas: CanvasCapability.shared)
            }
            .sheet(isPresented: $showGatewaySessions) {
                if let viewModel = gatewaySessionsViewModel {
                    NavigationStack {
                        SessionsView(viewModel: viewModel, onSelectSession: { session in
                            showGatewaySessions = false
                            openGatewaySession(session)
                        })
                    }
                }
            }
            .sheet(isPresented: $showKeyboardSettings) {
                NavigationStack {
                    KeyboardSettingsPlaceholderView()
                }
            }
            .tint(.openClawRed)
            .preferredColorScheme(settingsStore.settings.preferredColorScheme)
            .task {
                // 推送与后台刷新接线：首次申请通知权限、注册 APNs、注册 BGAppRefreshTask
                await PushManager.shared.requestNotificationPermissionIfNeeded()
                await ensureRemoteNotificationsRegistered()
                BGAppRefreshManager.shared.register()
                // 分享扩展轮询：App Group 有待发标记则读取并发送
                await checkPendingShareIfNeeded()
                // 语音唤醒接线：检测到唤醒词 -> 发通知 -> 主界面处理
                VoiceWakeCapability.shared.onKeywordDetected = { keyword in
                    NotificationCenter.default.post(name: .clawTalkWakeWordDetected, object: keyword)
                }
                // 语音唤醒看门狗：App 生命周期内常驻，每 10 秒自检自愈
                Task { await runVoiceWakeWatchdog() }
                guard settingsStore.settings.useWebSocket,
                      settingsStore.isConfigured else { return }

                // Connect operator WebSocket
                if gatewayConnection.connectionState == .disconnected {
                    await gatewayConnection.connect(
                        resolvedURL: settingsStore.settings.resolvedWebSocketURL,
                        token: settingsStore.gatewayToken
                    )
                    if gatewayConnection.connectionState == .disconnected,
                       let lastError = gatewayConnection.lastError {
                        LogCollector.record(module: "启动", "应用启动网关连接失败：\(AppErrorText.localized(lastError))")
                    }
                }

                // Connect node WebSocket
                if nodeConnection.connectionState == .disconnected {
                    await nodeConnection.connect(
                        resolvedURL: settingsStore.settings.resolvedWebSocketURL,
                        token: settingsStore.gatewayToken
                    )
                    if nodeConnection.connectionState == .disconnected,
                       let lastError = nodeConnection.lastError {
                        LogCollector.record(module: "启动", "应用启动节点连接失败：\(AppErrorText.localized(lastError))")
                    }
                }
            }
            .task {
                // 小组件数据 + 分享频道列表同步：App 生命周期内常驻，每 3 秒自检（仅变化时写入）
                await runWidgetAndShareSyncLoop()
            }
            .onChange(of: settingsStore.settings.ttsProvider) {
                reconfigureServices()
            }
            .onChange(of: settingsStore.settings.sttProvider) {
                reconfigureServices()
            }
            .onChange(of: settingsStore.settings.voiceInputEnabled) { _, enabled in
                if !enabled, chatViewModel?.isConversationMode == true {
                    chatViewModel?.exitConversationMode()
                }
                reconfigureServices()
            }
            .onChange(of: settingsStore.doubaoAPIKey) {
                reconfigureServices()
            }
            .onChange(of: settingsStore.elevenLabsAPIKey) {
                reconfigureServices()
            }
            .onChange(of: settingsStore.openAIAPIKey) {
                reconfigureServices()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background || newPhase == .inactive {
                    // 仅保存状态，不再停唤醒：退后台后继续监听唤醒词（UIBackgroundModes=audio 已开启）
                    chatViewModel?.saveCurrentState()
                    if newPhase == .background {
                        // 后台刷新接线：请求下一次 BGAppRefreshTask
                        BGAppRefreshManager.shared.scheduleRefresh()
                    }
                } else if newPhase == .active {
                    startVoiceWakeIfNeeded()
                    Task {
                        await checkPendingShareIfNeeded()
                        updateWidgetIfNeeded()
                    }
                }
            }
            .onChange(of: settingsStore.settings.voiceWakeEnabled) { _, enabled in
                if enabled {
                    startVoiceWakeIfNeeded()
                } else {
                    stopVoiceWake()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawTalkWakeWordDetected)) { _ in
                handleWakeWordDetected()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawTalkDeviceTokenDidChange)) { _ in
                Task { await PushManager.shared.reportIfConfigured(settings: settingsStore) }
            }
    }

    private func selectChannel(_ channel: Channel, restartVoiceWake: Bool = true) {
        selectedTab = 0
        // 三端同步频道（codex/claude）：不走网关 session，改用桥的 /sync 全历史 + 3 秒轮询
        if channel.agentId == "codex" || channel.agentId == "claude" {
            stopVoiceWake()
            syncChatViewModel = SyncChatViewModel(
                settings: settingsStore,
                agentId: channel.agentId,
                channelName: channel.name
            )
            chatViewModel = nil
            selectedChannel = channel
            selectedSyncChannel = channel
            nodeConnection.onImagesReceived = nil
            activeChatRoute = .sync
            return
        }

        let vm: ChatViewModel
        if let existing = backgroundViewModels.removeValue(forKey: channel.id) {
            // 复用后台继续任务的 VM，避免重建导致任务/消息丢失
            existing.isVisible = true
            vm = existing
        } else {
            vm = ChatViewModel(
                settings: settingsStore,
                channel: channel,
                channelStore: channelStore,
                gatewayConnection: gatewayConnection
            )
        }
        configureServices(for: vm)
        chatViewModel = vm
        selectedChannel = channel

        // Wire node image injection to chat
        nodeConnection.onImagesReceived = { [weak vm] images, caption in
            vm?.injectImages(images, caption: caption)
        }

        // Auto-connect WebSocket if enabled, then load server history
        if settingsStore.settings.useWebSocket, settingsStore.isConfigured {
            Task {
                if gatewayConnection.connectionState == .disconnected {
                    await gatewayConnection.connect(
                        resolvedURL: settingsStore.settings.resolvedWebSocketURL,
                        token: settingsStore.gatewayToken
                    )
                    if gatewayConnection.connectionState == .disconnected,
                       let lastError = gatewayConnection.lastError {
                        LogCollector.record(module: "启动", "进入频道网关连接失败：\(AppErrorText.localized(lastError))")
                    }
                }
                if nodeConnection.connectionState == .disconnected {
                    await nodeConnection.connect(
                        resolvedURL: settingsStore.settings.resolvedWebSocketURL,
                        token: settingsStore.gatewayToken
                    )
                    if nodeConnection.connectionState == .disconnected,
                       let lastError = nodeConnection.lastError {
                        LogCollector.record(module: "启动", "进入频道节点连接失败：\(AppErrorText.localized(lastError))")
                    }
                }
                vm.loadServerHistory()
            }
        }
        if restartVoiceWake {
            startVoiceWakeIfNeeded()
        }
        activeChatRoute = .chat
    }

    /// 网关会话入口：懒加载会话列表 ViewModel 并弹出全部会话列表
    private func openGatewaySessionsList() {
        if gatewaySessionsViewModel == nil {
            gatewaySessionsViewModel = ToolsViewModel(
                settings: settingsStore,
                gatewayConnection: gatewayConnection
            )
        }
        showGatewaySessions = true
    }

    /// 点选网关会话：复用 serverSessionKey 逻辑进入聊天（频道 agentId 从会话 key 提取）
    private func openGatewaySession(_ session: SessionEntry) {
        let agentId = session.key.split(separator: ":").dropFirst().first.map(String.init) ?? "main"
        let title = session.displayName ?? session.label
            ?? ToolsViewModel.friendlyTitle(for: session.key)
            ?? "会话 \(session.key.suffix(8))"
        var channel: Channel
        if let existing = channelStore.channels.first(where: { $0.serverSessionKey == session.key }) {
            channel = existing
        } else {
            channel = Channel(name: title, agentId: agentId, systemEmoji: "💬")
            channel.serverSessionKey = session.key
        }
        selectChannel(channel)
    }

    /// 聊天页返回（自绘返回按钮）：清空路由 → onChange 统一做退出清理。
    private func goBack() {
        activeChatRoute = nil
    }

    /// 聊天页退出清理：系统侧滑返回或自绘返回按钮共用（不销毁后台任务，完成后发通知）。
    private func handleChatRouteCleared() {
        stopVoiceWake()
        if syncChatViewModel != nil || selectedSyncChannel != nil {
            syncChatViewModel?.stopPolling()
            syncChatViewModel = nil
            selectedSyncChannel = nil
            selectedChannel = nil
            nodeConnection.onImagesReceived = nil
            return
        }
        guard let vm = chatViewModel else {
            selectedChannel = nil
            nodeConnection.onImagesReceived = nil
            return
        }

        // 退出聊天页：不 abort / 不 cancel，任务在后台继续，完成后发本地通知
        if vm.isConversationMode {
            vm.exitConversationMode() // 停录音但不取消任务
        }
        vm.isVisible = false

        // 进行中任务：保留 VM 到后台，完成后由 onRunFinished 发通知
        let isInFlight = vm.state != .idle
            || vm.messages.contains(where: { $0.role == .assistant && $0.isStreaming })
        if isInFlight {
            vm.onRunFinished = { finishedVM, success, snippet in
                guard !finishedVM.isVisible else { return }
                let title = success ? "任务完成" : "任务失败"
                let body = snippet ?? (success ? "对话已处理完毕" : "后台任务出现问题，请回聊天页查看")
                Task {
                    try? await NotificationCapability.notify(title: title, body: body, sound: nil, priority: "urgent")
                }
            }
            backgroundViewModels[vm.channel.id] = vm
        }
        chatViewModel = nil
        selectedChannel = nil
        nodeConnection.onImagesReceived = nil
    }
    private func deleteCurrentChannel() {
        stopVoiceWake()
        if let vm = chatViewModel {
            vm.stop() // 真正取消：abort + cancel
            backgroundViewModels.removeValue(forKey: vm.channel.id)
        }
        if let channel = selectedSyncChannel {
            channelStore.delete(channel)
        } else if let channel = selectedChannel {
            channelStore.delete(channel)
        }
        syncChatViewModel?.stopPolling()
        syncChatViewModel = nil
        selectedSyncChannel = nil
        chatViewModel = nil
        selectedChannel = nil
        nodeConnection.onImagesReceived = nil
    }

    // MARK: - 语音唤醒（SIRI 式）

    /// 已开启语音唤醒且未处于免提对话时启动唤醒词监听（前台/后台均可，退后台持续监听）。
    private func startVoiceWakeIfNeeded() {
        // 幂等：已在监听则不重复启动，避免「语音唤醒已在运行」噪音（日志 23:44/23:38）
        guard !VoiceWakeCapability.shared.isListening else { return }
        guard settingsStore.settings.voiceWakeEnabled else { return }
        guard settingsStore.settings.voiceInputEnabled else { return }
        if let vm = chatViewModel, vm.isConversationMode { return }
        let words = settingsStore.settings.voiceWakeWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        VoiceWakeCapability.shared.autoRestartsAfterDetection = false
        Task {
            let result = try? await VoiceWakeCapability.shared.setConfig(keywords: words, enabled: true, locale: "zh-CN")
            if result?.enabled == true {
                // 监听期间：锁屏/灵动岛显示「随时唤醒」
                ClawTalkLiveActivity.startWakeListening()
            }
        }
    }

    /// 停止唤醒词监听（同步停引擎 + 异步同步配置状态），并收起「随时唤醒」锁屏状态。
    private func stopVoiceWake() {
        VoiceWakeCapability.shared.stopListening()
        ClawTalkLiveActivity.endWakeListening()
        Task {
            _ = try? await VoiceWakeCapability.shared.setConfig(keywords: [], enabled: false, locale: "zh-CN")
        }
    }

    /// 语音唤醒看门狗：App 生命周期内每 10 秒自检一次，监听被系统中断后自动自愈。
    /// 不随 scenePhase 取消；对话模式/按住说话录音期间不误拉。
    private func runVoiceWakeWatchdog() async {
        voiceWakeWatchdogTask?.cancel()
        let task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                let shouldRestart = settingsStore.settings.voiceWakeEnabled
                    && settingsStore.settings.voiceInputEnabled
                    && chatViewModel?.isConversationMode != true
                    && chatViewModel?.state != .recording
                    && !VoiceWakeCapability.shared.isListening
                if shouldRestart {
                    startVoiceWakeIfNeeded()
                }
            }
        }
        voiceWakeWatchdogTask = task
        await task.value
    }

    /// 唤醒词命中：停唤醒 -> 自动选/建频道（无聊天页时）-> 进入免提对话 -> 播报「在呢」。
    private func handleWakeWordDetected() {
        stopVoiceWake()
        guard settingsStore.settings.voiceInputEnabled else {
            startVoiceWakeIfNeeded()
            return
        }
        if chatViewModel == nil {
            ensureDefaultChannel()
        }
        guard let vm = chatViewModel,
              !vm.isConversationMode,
              vm.state == .idle
        else {
            startVoiceWakeIfNeeded()
            return
        }
        vm.enterConversationMode()
        speakAck()
    }

    /// 后台命中唤醒词且当前没有打开的聊天页时，优先进入设置里选的「唤醒后进入的频道」，
    /// 找不到所选频道则回退现有第一个频道（没有则创建默认频道），
    /// 不重启唤醒（免提对话即将接管麦克风）。
    private func ensureDefaultChannel() {
        guard chatViewModel == nil else { return }
        let channel: Channel
        if let wakeChannelID = settingsStore.settings.voiceWakeChannelID,
           let matched = channelStore.channels.first(where: { $0.id.uuidString == wakeChannelID }) {
            channel = matched
        } else if let first = channelStore.channels.first {
            channel = first
        } else {
            channel = .default
            channelStore.add(channel)
        }
        selectChannel(channel, restartVoiceWake: false)
    }

    /// 播报「在呢」确认（保留 synthesizer 引用，防止提前释放导致不出声）。
    private func speakAck() {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "在呢")
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        synthesizer.speak(utterance)
        ackSynthesizer = synthesizer
    }

    private func reconfigureServices() {
        guard let vm = chatViewModel else { return }
        configureServices(for: vm)
    }

    private func configureServices(for vm: ChatViewModel) {
        let secure = SecureStorage.shared
        let s = settingsStore.settings

        // STT: Apple 系统识别 / OpenClaw Backend / 豆包（Doubao）
        let stt: (any TranscriptionService)?
        if !s.voiceInputEnabled {
            stt = nil
        } else {
            switch s.sttProvider {
            case .apple:
                stt = AppleSTTService(language: s.whisperLanguage)
            case .doubao:
                if let key = secure.doubaoAPIKey, !key.isEmpty {
                    stt = DoubaoSTTService(apiKey: key, language: s.whisperLanguage)
                } else {
                    stt = AppleSTTService(language: s.whisperLanguage)
                }
            }
        }

        // TTS
        let tts: any SpeechService = {
            switch s.ttsProvider {
            case .apple:
                return AppleTTSService(speed: s.ttsSpeed, pitch: s.ttsPitch)
            case .doubao:
                if let key = secure.doubaoAPIKey, !key.isEmpty {
                    return DoubaoTTSService(apiKey: key, voiceID: s.doubaoVoiceID)
                }
                return AppleTTSService(speed: s.ttsSpeed, pitch: s.ttsPitch)
            case .edge:
                return EdgeTTSService(voiceID: s.edgeVoiceID, speed: s.ttsSpeed, pitch: s.ttsPitch)
            }
        }()

        vm.configure(transcription: stt, speech: tts)
    }
    // MARK: - 深链接（clawtalk://）

    /// 深链接接线：pair/connect 写入网关配置；open 按频道名选中进入。
    /// 深链接统一入口：SOS 优先，其余走既有 DeepLinkHandler。
    private func handleIncomingURL(_ url: URL) {
        if EmergencyStore.handleSOSDeepLink(url) {
            return
        }
        // 键盘设置深链接：clawtalk://keyboard-settings 或 clawtalk://keyboard → 弹「键盘」设置页（键盘包搬入前为占位页）
        if url.scheme?.lowercased() == DeepLinkHandler.scheme,
           let host = url.host?.lowercased(),
           host == "keyboard-settings" || host == "keyboard" {
            showKeyboardSettings = true
            return
        }
        handleDeepLink(url)
    }

    private func handleDeepLink(_ url: URL) {
        guard DeepLinkHandler.handle(url, settings: settingsStore),
              let payload = DeepLinkHandler.parse(url),
              payload.action == .open,
              let name = payload.channelName
        else { return }
        if let channel = channelStore.channels.first(where: { $0.name == name }) {
            selectChannel(channel)
        }
    }

    // MARK: - 远程推送

    /// 通知权限已授权/临时授权时向系统注册 APNs（拿到 deviceToken 后由 onReceive 上报网关）。
    private func ensureRemoteNotificationsRegistered() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            PushManager.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    // MARK: - 分享扩展轮询（App Group: group.7518554）

    private static let shareSuiteName = "group.7518554"
    private static let pendingShareFlagKey = "pending_share_flag"
    private static let pendingShareMessageKey = "pending_share_message"
    private static let shareChannelsKey = "channels_list"

    /// 分享扩展写入的待发消息契约（与 ClawTalkShareExtension/ShareConstants.swift 保持一致）。
    private struct PendingShareMessage: Codable {
        var channelId: String
        var channelName: String
        var text: String
        var attachments: [PendingShareAttachment]
        var createdAt: TimeInterval
    }

    private struct PendingShareAttachment: Codable {
        var fileName: String
        var containerPath: String
        var mimeType: String
    }

    private struct ShareChannelEntry: Codable {
        let id: String
        var name: String
        var agentId: String?
    }

    /// 启动/进前台轮询：pending_share_flag=true 时读取消息与附件，通过目标频道发送，成功后清标记。
    private func checkPendingShareIfNeeded() async {
        guard settingsStore.isConfigured,
              let groupDefaults = UserDefaults(suiteName: Self.shareSuiteName),
              groupDefaults.bool(forKey: Self.pendingShareFlagKey)
        else { return }

        guard let data = groupDefaults.data(forKey: Self.pendingShareMessageKey),
              let pending = try? JSONDecoder().decode(PendingShareMessage.self, from: data)
        else {
            // 消息数据缺失/损坏：清标记，避免反复轮询
            groupDefaults.set(false, forKey: Self.pendingShareFlagKey)
            return
        }

        let channel: Channel
        if let existing = channelStore.channels.first(where: { $0.id.uuidString == pending.channelId }) {
            channel = existing
        } else if let matched = channelStore.channels.first(where: { $0.name == pending.channelName }) {
            channel = matched
        } else {
            channel = Channel(
                name: pending.channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "分享"
                    : pending.channelName,
                agentId: "main"
            )
            channelStore.add(channel)
        }

        var images: [Data] = []
        var text = pending.text
        for attachment in pending.attachments {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: attachment.containerPath)) else {
                text += "\n[附件读取失败：\(attachment.fileName)]"
                continue
            }
            if attachment.mimeType.lowercased().hasPrefix("image/") {
                images.append(data)
            } else {
                text += "\n[附件：\(attachment.fileName)（\(attachment.mimeType)）]"
            }
        }

        if await sendShareMessage(text: text, images: images, channel: channel) {
            groupDefaults.set(false, forKey: Self.pendingShareFlagKey)
            groupDefaults.synchronize()
            LogCollector.record(module: "分享", "已把分享内容发送到频道「\(channel.name)」")
        } else {
            LogCollector.record(module: "分享", "分享内容发送失败，保留待发标记，下次进前台重试")
        }
    }

    /// 通过频道发送分享内容：聊天页开着该频道走 ViewModel；否则走网关 WebSocket（不等待完整回复）。
    @discardableResult
    private func sendShareMessage(text: String, images: [Data], channel: Channel) async -> Bool {
        if let vm = chatViewModel, vm.channel.id == channel.id, vm.isVisible {
            vm.sendText(text, images: images)
            return true
        }
        guard settingsStore.settings.useWebSocket else { return false }
        if gatewayConnection.connectionState == .disconnected {
            await gatewayConnection.connect(
                resolvedURL: settingsStore.settings.resolvedWebSocketURL,
                token: settingsStore.gatewayToken
            )
        }
        guard gatewayConnection.connectionState == .connected else { return false }
        do {
            _ = try await gatewayConnection.chatSend(
                sessionKey: shareSessionKey(for: channel),
                message: text,
                images: images.isEmpty ? nil : images
            )
            return true
        } catch {
            LogCollector.record(module: "分享", "WebSocket 发送失败：\(AppErrorText.localized(error.localizedDescription))")
            return false
        }
    }

    /// 与 ChatViewModel.sessionKey 保持一致的会话 key 计算（外部会话优先，否则按频道 ID 派生）。
    private func shareSessionKey(for channel: Channel) -> String {
        if let external = channel.serverSessionKey, !external.isEmpty { return external }
        let deviceID = OpenClawClient().deviceID
        let base = "agent:\(channel.agentId):clawtalk-user:\(deviceID):\(channel.id.uuidString.prefix(8).lowercased())"
        return channel.sessionVersion > 0 ? "\(base)-v\(channel.sessionVersion)" : base
    }

    /// 主 App 写入频道列表（JSON 数组），供分享扩展的频道选择器读取。
    private func syncChannelsToShare() {
        guard let groupDefaults = UserDefaults(suiteName: Self.shareSuiteName) else { return }
        let signature = channelStore.channels
            .map { "\($0.id.uuidString)|\($0.name)|\($0.agentId)" }
            .joined(separator: "\n")
        guard signature != syncedChannelsSignature else { return }
        syncedChannelsSignature = signature
        let entries = channelStore.channels.map {
            ShareChannelEntry(id: $0.id.uuidString, name: $0.name, agentId: $0.agentId)
        }
        if let data = try? JSONEncoder().encode(entries) {
            groupDefaults.set(data, forKey: Self.shareChannelsKey)
            groupDefaults.synchronize()
        }
    }

    // MARK: - 主屏小组件数据写入（App Group: group.7518554）

    private static let widgetSuiteName = "group.7518554"
    private static let widgetChannelNameKey = "widget_channel_name"
    private static let widgetGatewayStatusKey = "widget_gateway_status"
    private static let widgetRecentSessionKey = "widget_recent_session"
    private static let widgetUpdatedAtKey = "widget_updated_at"

    private struct WidgetSnapshot: Equatable {
        var channelName: String
        var gatewayStatus: String
        var recentSession: String
    }

    private func currentWidgetSnapshot() -> WidgetSnapshot {
        let status: String
        switch gatewayConnection.connectionState {
        case .connected: status = "已连接"
        case .connecting: status = "连接中"
        case .disconnected: status = "未连接"
        }
        let channelName = selectedChannel?.name
            ?? chatViewModel?.channel.name
            ?? channelStore.channels.first?.name
            ?? ""
        var recentSession = ""
        if let vm = chatViewModel,
           let last = vm.messages.reversed().first(where: { !$0.isStreaming && !$0.content.isEmpty }) {
            recentSession = String(last.content.prefix(60))
        }
        return WidgetSnapshot(
            channelName: channelName,
            gatewayStatus: status,
            recentSession: recentSession
        )
    }

    /// 连接状态/最近会话变化时写入小组件键（仅变化时写），并刷新小组件时间线。
    private func updateWidgetIfNeeded() {
        guard let groupDefaults = UserDefaults(suiteName: Self.widgetSuiteName) else { return }
        let snapshot = currentWidgetSnapshot()
        guard snapshot != widgetSnapshot else { return }
        widgetSnapshot = snapshot
        groupDefaults.set(snapshot.channelName, forKey: Self.widgetChannelNameKey)
        groupDefaults.set(snapshot.gatewayStatus, forKey: Self.widgetGatewayStatusKey)
        groupDefaults.set(snapshot.recentSession, forKey: Self.widgetRecentSessionKey)
        groupDefaults.set(Date().timeIntervalSince1970, forKey: Self.widgetUpdatedAtKey)
        groupDefaults.synchronize()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 小组件 + 分享频道列表同步循环：App 生命周期内常驻，每 3 秒自检（仅在变化时写入）。
    private func runWidgetAndShareSyncLoop() async {
        syncChannelsToShare()
        updateWidgetIfNeeded()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            syncChannelsToShare()
            updateWidgetIfNeeded()
        }
    }

// MARK: - 侧滑返回兜底（N5）

/// iOS 17 TabView 内 NavigationStack push 后 interactive pop 偶发失效，
/// 用隐藏 UIViewController 强制启用 UINavigationController 的返回手势。
private struct EnableSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isHidden = true
        DispatchQueue.main.async {
            if let nav = controller.navigationController {
                nav.interactivePopGestureRecognizer?.isEnabled = true
                nav.interactivePopGestureRecognizer?.delegate = nil
            }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
}
