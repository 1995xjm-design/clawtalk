    var body: some Scene {
        WindowGroup {
            windowContent
        }
    }

    /// WindowGroup 内容（拆出独立计算属性，避免 SwiftUI 类型检查超时）
    @ViewBuilder
    private var windowContent: some View {
            Group {
                if !settingsStore.hasCompletedOnboarding {
                    OnboardingView(settingsStore: settingsStore) {
                        // Onboarding complete
                    }
                } else {
                    mainZStack
                }
            }
            .onOpenURL { url in
                handleDeepLink(url)
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
            .tint(.openClawRed)
            .preferredColorScheme(settingsStore.settings.appearance == .dark ? .dark : .light)
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