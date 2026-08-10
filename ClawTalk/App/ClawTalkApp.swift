import SwiftUI
import AVFoundation
import Combine

@main
struct ClawTalkApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsStore: SettingsStore
    @State private var channelStore: ChannelStore
    @State private var selectedChannel: Channel?
    @State private var showFileTransferChannel = false
    @State private var chatViewModel: ChatViewModel?
    @State private var gatewayConnection = GatewayConnection()
    @State private var nodeConnection = NodeConnection()
    @State private var ackSynthesizer: AVSpeechSynthesizer?

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
        ZStack {
        ChannelListView(
        channelStore: channelStore,
        settingsStore: settingsStore,
        gatewayConnection: gatewayConnection,
        onSelect: { channel in
        selectChannel(channel)
        },
        onSelectFileTransfer: { showFileTransferChannel = true }
        )
        .zIndex(0)
                if let vm = chatViewModel, selectedChannel != nil {
        ChatView(viewModel: vm, settingsStore: settingsStore, gatewayConnection: gatewayConnection, onBack: goBack, onDeleteChannel: deleteCurrentChannel)
        .zIndex(1)
        .onChange(of: vm.isConversationMode) { _, isOn in
        if isOn {
        stopVoiceWake()
        } else {
        startVoiceWakeIfNeeded()
        }
        }
        }
                if showFileTransferChannel {
        FileTransferChannelView(
        settings: settingsStore,
        onBack: { showFileTransferChannel = false }
        )
        .zIndex(1)
        }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !settingsStore.hasCompletedOnboarding {
                    OnboardingView(settingsStore: settingsStore) {
                        // Onboarding complete
                    }
                } else {
                    mainZStack
                }
            }
            .overlay {
                ApprovalOverlayView(gatewayConnection: gatewayConnection)
            }
            .sheet(isPresented: Binding(
                get: { CanvasCapability.shared.isPresented },
                set: { CanvasCapability.shared.isPresented = $0 }
            )) {
                CanvasView(canvas: CanvasCapability.shared)
            }
            .tint(.openClawRed)
            .preferredColorScheme(settingsStore.settings.appearance == .dark ? .dark : .light)
            .task {
                // 语音唤醒接线：检测到唤醒词 -> 发通知 -> 主界面处理
                VoiceWakeCapability.shared.onKeywordDetected = { keyword in
                    NotificationCenter.default.post(name: .clawTalkWakeWordDetected, object: keyword)
                }
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
                } else if newPhase == .active {
                    startVoiceWakeIfNeeded()
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
        }
    }

    private func selectChannel(_ channel: Channel, restartVoiceWake: Bool = true) {
        let vm = ChatViewModel(
            settings: settingsStore,
            channel: channel,
            channelStore: channelStore,
            gatewayConnection: gatewayConnection
        )
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
    }

    private func goBack() {
        stopVoiceWake()
        chatViewModel?.stop()
        chatViewModel = nil
        selectedChannel = nil
        nodeConnection.onImagesReceived = nil
    }

    private func deleteCurrentChannel() {
        stopVoiceWake()
        chatViewModel?.stop()
        if let channel = selectedChannel {
            channelStore.delete(channel)
        }
        chatViewModel = nil
        selectedChannel = nil
    }

    // MARK: - 语音唤醒（SIRI 式）

    /// 已开启语音唤醒且未处于免提对话时启动唤醒词监听（前台/后台均可，退后台持续监听）。
    private func startVoiceWakeIfNeeded() {
        guard settingsStore.settings.voiceWakeEnabled else { return }
        guard settingsStore.settings.voiceInputEnabled else { return }
        if let vm = chatViewModel, vm.isConversationMode { return }
        let word = settingsStore.settings.voiceWakeWord
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        VoiceWakeCapability.shared.autoRestartsAfterDetection = false
        Task {
            let result = try? await VoiceWakeCapability.shared.setConfig(keywords: [word], enabled: true, locale: "zh-CN")
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

    /// 后台命中唤醒词且当前没有打开的聊天页时，自动选中现有第一个频道（没有则创建默认频道），
    /// 不重启唤醒（免提对话即将接管麦克风）。
    private func ensureDefaultChannel() {
        guard chatViewModel == nil else { return }
        let channel: Channel
        if let first = channelStore.channels.first {
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
                return AppleTTSService()
            case .doubao:
                if let key = secure.doubaoAPIKey, !key.isEmpty {
                    return DoubaoTTSService(apiKey: key, voiceID: s.doubaoVoiceID)
                }
                return AppleTTSService()
            case .edge:
                return EdgeTTSService(voiceID: s.edgeVoiceID)
            }
        }()

        vm.configure(transcription: stt, speech: tts)
    }
}
