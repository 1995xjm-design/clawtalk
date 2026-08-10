import SwiftUI

@main
struct ClawTalkApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsStore: SettingsStore
    @State private var channelStore: ChannelStore
    @State private var selectedChannel: Channel?
    @State private var chatViewModel: ChatViewModel?
    @State private var gatewayConnection = GatewayConnection()
    @State private var nodeConnection = NodeConnection()

    init() {
        #if DEBUG
        DemoDataSeeder.seedIfNeeded()
        #endif
        _settingsStore = State(initialValue: SettingsStore())
        _channelStore = State(initialValue: ChannelStore.shared)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !settingsStore.hasCompletedOnboarding {
                    OnboardingView(settingsStore: settingsStore) {
                        // Onboarding complete
                    }
                } else {
                    // 底层常驻频道列表，聊天页浮在上面（支持跟手滑出）
                    ZStack {
                        ChannelListView(
                            channelStore: channelStore,
                            settingsStore: settingsStore,
                            gatewayConnection: gatewayConnection,
                            onSelect: { channel in
                                selectChannel(channel)
                            }
                        )
                        .zIndex(0)

                        if let vm = chatViewModel, selectedChannel != nil {
                            ChatView(viewModel: vm, settingsStore: settingsStore, gatewayConnection: gatewayConnection, onBack: goBack, onDeleteChannel: deleteCurrentChannel)
                                .zIndex(1)
                        }
                    }
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
                    chatViewModel?.saveCurrentState()
                }
            }
        }
    }

    private func selectChannel(_ channel: Channel) {
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
    }

    private func goBack() {
        chatViewModel?.stop()
        chatViewModel = nil
        selectedChannel = nil
        nodeConnection.onImagesReceived = nil
    }

    private func deleteCurrentChannel() {
        chatViewModel?.stop()
        if let channel = selectedChannel {
            channelStore.delete(channel)
        }
        chatViewModel = nil
        selectedChannel = nil
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
            }
        }()

        vm.configure(transcription: stt, speech: tts)
    }
}
