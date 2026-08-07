import SwiftUI

@main
struct ClawTalkApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsStore: SettingsStore
    @State private var channelStore: ChannelStore
    @State private var selectedChannel: Channel?
    @State private var chatViewModel: ChatViewModel?
    @State private var showModelDownload = false
    @State private var modelManager = WhisperModelManager.shared
    @State private var cachedSTT: WhisperKitService?
    @State private var cachedSTTModelSize: WhisperModelSize?
    @State private var gatewayConnection = GatewayConnection()
    @State private var nodeConnection = NodeConnection()

    init() {
        #if DEBUG
        DemoDataSeeder.seedIfNeeded()
        #endif
        _settingsStore = State(initialValue: SettingsStore())
        _channelStore = State(initialValue: ChannelStore())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !settingsStore.hasCompletedOnboarding {
                    OnboardingView(settingsStore: settingsStore) {
                        // Onboarding complete
                    }
                } else if showModelDownload {
                    ModelDownloadView(
                        modelSize: settingsStore.settings.whisperModelSize,
                        onComplete: {
                            showModelDownload = false
                        },
                        onSkip: {
                            showModelDownload = false
                        }
                    )
                } else if let vm = chatViewModel, selectedChannel != nil {
                    ChatView(viewModel: vm, settingsStore: settingsStore, gatewayConnection: gatewayConnection, onBack: goBack, onDeleteChannel: deleteCurrentChannel)
                } else {
                    ChannelListView(
                        channelStore: channelStore,
                        settingsStore: settingsStore,
                        gatewayConnection: gatewayConnection,
                        onSelect: { channel in
                            selectChannel(channel)
                        }
                    )
                    .onAppear {
                        if !modelManager.hasDownloadedModel && settingsStore.settings.voiceInputEnabled {
                            showModelDownload = true
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
                // Pre-warm WhisperKit at app launch so the first
                // conversation-mode utterance doesn't pay the 3s
                // CoreML cold-load cost. Triggers Task.detached load
                // inside the service's init; the eager work runs in
                // the background while the user navigates to a chat.
                if settingsStore.settings.sttProvider == .local,
                   settingsStore.settings.voiceInputEnabled,
                   modelManager.hasDownloadedModel,
                   cachedSTT == nil {
                    let warmup = WhisperKitService(modelSize: settingsStore.settings.whisperModelSize)
                    cachedSTT = warmup
                    cachedSTTModelSize = settingsStore.settings.whisperModelSize
                }

                guard settingsStore.settings.useWebSocket,
                      settingsStore.isConfigured else { return }

                // Connect operator WebSocket
                if gatewayConnection.connectionState == .disconnected {
                    await gatewayConnection.connect(
                        resolvedURL: settingsStore.settings.resolvedWebSocketURL,
                        token: settingsStore.gatewayToken
                    )
                }

                // Connect node WebSocket
                if nodeConnection.connectionState == .disconnected {
                    await nodeConnection.connect(
                        resolvedURL: settingsStore.settings.resolvedWebSocketURL,
                        token: settingsStore.gatewayToken
                    )
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
            .onChange(of: settingsStore.settings.whisperModelSize) {
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
                }
                if nodeConnection.connectionState == .disconnected {
                    await nodeConnection.connect(
                        resolvedURL: settingsStore.settings.resolvedWebSocketURL,
                        token: settingsStore.gatewayToken
                    )
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

        // STT: Local Whisper transcribes on-device; OpenClaw Backend
        // relays audio to the fusion-backend /api/stt endpoint. The
        // on-device service stays cached while the local provider is
        // active; the backend provider is created per configuration.
        let stt: (any TranscriptionService)?
        if !s.voiceInputEnabled {
            cachedSTT = nil
            cachedSTTModelSize = nil
            stt = nil
        } else {
            switch s.sttProvider {
            case .local:
                if let cached = cachedSTT, cachedSTTModelSize == s.whisperModelSize {
                    stt = cached
                } else {
                    let service = WhisperKitService(modelSize: s.whisperModelSize)
                    cachedSTT = service
                    cachedSTTModelSize = s.whisperModelSize
                    stt = service
                }
            case .openclaw:
                let backendURL = s.fusionBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if backendURL.isEmpty {
                    // Fall back to on-device Whisper when no backend URL is configured.
                    if let cached = cachedSTT, cachedSTTModelSize == s.whisperModelSize {
                        stt = cached
                    } else {
                        let service = WhisperKitService(modelSize: s.whisperModelSize)
                        cachedSTT = service
                        cachedSTTModelSize = s.whisperModelSize
                        stt = service
                    }
                } else {
                    cachedSTT = nil
                    cachedSTTModelSize = nil
                    stt = OpenClawSTTService(backendURL: backendURL, language: nil)
                }
            }
        }

        // TTS
        let tts: any SpeechService = {
            switch s.ttsProvider {
            case .elevenlabs:
                if let key = secure.elevenLabsAPIKey, !key.isEmpty {
                    return ElevenLabsTTSService(voiceID: s.elevenLabsVoiceID, apiKey: key)
                }
                return AppleTTSService()
            case .openai:
                if let key = secure.openAIAPIKey, !key.isEmpty {
                    return OpenAITTSService(voice: s.openAIVoice, apiKey: key)
                }
                return AppleTTSService()
            case .openclaw:
                let backendURL = s.fusionBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if backendURL.isEmpty {
                    return AppleTTSService()
                }
                return OpenClawTTSService(backendURL: backendURL, voice: nil)
            case .minimax:
                let groupID = s.minimaxGroupID.trimmingCharacters(in: .whitespacesAndNewlines)
                let apiKey = s.minimaxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if groupID.isEmpty || apiKey.isEmpty {
                    // MiniMax 配置缺失时兜底 Apple 语音
                    return AppleTTSService()
                }
                return MiniMaxTTSService(
                    groupID: groupID,
                    apiKey: apiKey,
                    domain: s.minimaxDomain,
                    voiceID: s.minimaxVoiceID
                )
            case .apple:
                return AppleTTSService()
            case .kokoro:
                return KokoroTTSService()
            }
        }()

        vm.configure(transcription: stt, speech: tts)
    }
}
