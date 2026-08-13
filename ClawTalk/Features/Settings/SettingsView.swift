import PhotosUI
import SwiftUI
import HamsteriOS

struct SettingsView: View {
    @Bindable var store: SettingsStore
    var gatewayConnection: GatewayConnection
    var nodeConnection: NodeConnection? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("clawtalk_wechat_connected") private var wechatConnected = false

    @State private var connectionTestState: ConnectionTestState = .idle
    @State private var showResetConfirm = false
    @State private var pendingReset: ResetOption?
    @State private var gatewayProfileStore = GatewayProfileStore()
    @State private var showScanPairing = false
    @State private var scanNotice: String?
    @State private var rescanToken = 0
    @State private var pairingMessage: String?
    @State private var showPairingResult = false
    @State private var deepSeekKey: String = SecureStorage.shared.getString("deepseek_api_key") ?? ""
    @State private var memorySyncMessage: String?
    @State private var setupCodeInput = ""
    @State private var isPairing = false
    @State private var isRequestingPairingCode = false


    // MARK: - 唤醒词编辑（本地 UUID 列表，避免 ForEach(id: \.offset) 删除/编辑越界崩溃）

    /// 唤醒词列表变更且引擎正在监听时热更新（ClawTalkApp 只监听开关变化，词表变化需此处补齐）。
    private func hotReloadVoiceWakeKeywords() {
        guard store.settings.voiceWakeEnabled, VoiceWakeCapability.shared.isListening else { return }
        let words = store.settings.voiceWakeWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        Task { @MainActor in
            VoiceWakeCapability.shared.stopListening()
            _ = try? await VoiceWakeCapability.shared.setConfig(keywords: words, enabled: true, locale: "zh-CN")
        }
    }

    enum ResetOption: String, CaseIterable, Identifiable {
        case onboarding = "仅重置新手引导"
        case gateway = "重置引导并清除网关配置"
        case full = "完全重置（含聊天记录）"
        var id: String { rawValue }
    }

    enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                pairingSection
            keyboardSection
                skinSection
                voiceSettingsSection
                voiceAgentSection
                displaySection
                wechatSection
                dataSection
                securitySection
                privacySection
                aboutSection
                diagnosticsSection
                resetSection
                            integrationSection
            }
            .confirmationDialog("重置新手引导", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("仅重置新手引导") { performReset(.onboarding) }
                Button("重置引导并清除网关配置") { performReset(.gateway) }
                Button("完全重置（含聊天记录）", role: .destructive) { performReset(.full) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请选择重置范围：")
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: deepSeekKey) { _, newValue in
                SecureStorage.shared.setString(newValue.isEmpty ? nil : newValue, forKey: "deepseek_api_key")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        scanNotice = nil
                        showScanPairing = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("扫码配对")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                            sanitizeVoiceWakeWords()
                            store.save()
                            hotReloadVoiceWakeKeywords()
                            dismiss()
                        }
                        .fontWeight(.semibold)
                }
            }
            .alert("同步电脑记忆", isPresented: Binding(
                get: { memorySyncMessage != nil },
                set: { if !$0 { memorySyncMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(memorySyncMessage ?? "")
            }
            .alert("扫码配对", isPresented: $showPairingResult) {
                Button("好", role: .cancel) {}
            } message: {
                Text(pairingMessage ?? "")
            }
            .fullScreenCover(isPresented: $showScanPairing) {
                QRScannerView(
                    onScan: { value in
                        if handlePairingCode(value) {
                            showScanPairing = false
                        } else {
                            rescanToken += 1
                            scanNotice = "无法识别配对码，请重新扫描"
                        }
                    },
                    onCancel: { showScanPairing = false },
                    scanNotice: scanNotice,
                    rescanToken: rescanToken
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - 扫码配对（换电脑/换网关一键重新配对）

    @discardableResult
    private func handlePairingCode(_ raw: String) -> Bool {
        guard let code = GatewaySetupCode.parse(raw) else {
            pairingMessage = "无法识别配对码，请重新扫码"
            showPairingResult = true
            return false
        }
        let httpURL = GatewaySetupCode.httpForm(of: code.url)
        store.settings.gatewayURL = httpURL
        store.settings.bootstrapToken = code.bootstrapToken
        store.settings.useWebSocket = true
        store.save()
        Task { @MainActor in
            await testPairing(bootstrapToken: code.bootstrapToken)
        }
        return true
    }

    @MainActor
    private func testPairing(bootstrapToken: String) async {
        let resolved = store.settings.resolvedWebSocketURL
        guard !resolved.isEmpty, let wsURL = URL(string: resolved) else {
            pairingMessage = "无效的网关地址"
            showPairingResult = true
            return
        }
        let gateway = GatewayWebSocket(
            url: wsURL,
            token: nil,
            bootstrapToken: bootstrapToken,
            deviceTokenHandler: { [store] deviceToken in
                Task { @MainActor in
                    store.gatewayToken = deviceToken
                    store.save()
                }
            }
        )
        do {
            try await gateway.connect()
            await gateway.shutdown()
            pairingMessage = "配对成功，网关令牌已更新"
        } catch {
            await gateway.shutdown()
            pairingMessage = "配对失败：\(AppErrorText.localized(error.localizedDescription))"
        }
        showPairingResult = true
    }

    // MARK: - WS 设备配对（输入 setup code / 获取配对码指令）

    /// 用输入的配对码开始配对：写入网关地址 + bootstrapToken，走 bootstrap 握手。
    private func startPairingWithSetupCode() {
        let raw = setupCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code = GatewaySetupCode.parse(raw) else {
            pairingMessage = "无法识别配对码：请粘贴 openclaw qr 输出的完整配对码（base64 或 JSON 均可）。"
            showPairingResult = true
            return
        }
        isPairing = true
        let httpURL = GatewaySetupCode.httpForm(of: code.url)
        store.settings.gatewayURL = httpURL
        store.settings.bootstrapToken = code.bootstrapToken
        store.settings.useWebSocket = true
        store.save()
        Task { @MainActor in
            defer { isPairing = false }
            await testPairing(bootstrapToken: code.bootstrapToken)
        }
    }

    /// 通过现有指令通道让网关返回 setup code 显示（openclaw qr 生成配对码）。
    private func requestPairingCodeFromGateway() {
        let gw = store.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !gw.isEmpty else {
            pairingMessage = "请先配置网关地址，再获取配对码。"
            showPairingResult = true
            return
        }
        guard !store.gatewayToken.isEmpty else {
            pairingMessage = "请先配置网关令牌，再获取配对码。"
            showPairingResult = true
            return
        }
        InstructionChannels.ensureChannel(name: "日志诊断", systemEmoji: "🩺", sessionKey: InstructionChannels.diagnostics)
        isRequestingPairingCode = true
        let instruction = """
        请在电脑端运行 openclaw qr 命令生成配对码（base64 字符串），
        把输出的完整配对码原样回复给我（不要省略、不要转义、不要加解释），回复只需包含配对码本身。
        """
        Task {
            defer { isRequestingPairingCode = false }
            do {
                let reply = try await OpenClawClient().chat(
                    messages: [Message(role: .user, content: instruction)],
                    gatewayURL: gw,
                    token: store.gatewayToken,
                    sessionKey: InstructionChannels.diagnostics
                )
                pairingMessage = reply
                // 若回复本身就是配对码，直接填入输入框方便一键配对
                if GatewaySetupCode.parse(reply) != nil {
                    setupCodeInput = reply
                }
            } catch {
                pairingMessage = "获取配对码失败：\(AppErrorText.localized(error.localizedDescription))"
            }
            showPairingResult = true
        }
    }

    private var pairingSection: some View {
        Section {
            TextField("粘贴配对码（openclaw qr 输出的 setup code）", text: $setupCodeInput, axis: .vertical)
                .lineLimit(1...3)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.caption)

            Button {
                startPairingWithSetupCode()
            } label: {
                if isPairing {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("正在配对…")
                    }
                } else {
                    Label("开始配对", systemImage: "link.badge.plus")
                }
            }
            .disabled(
                setupCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isPairing
            )

            Button {
                requestPairingCodeFromGateway()
            } label: {
                if isRequestingPairingCode {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("正在向网关获取配对码…")
                    }
                } else {
                    Label("获取配对码指令", systemImage: "qrcode")
                }
            }
            .disabled(isRequestingPairingCode)
        } header: {
            Text("配对设备")
        } footer: {
            Text("电脑端运行 openclaw qr 生成配对码（base64），粘贴后点「开始配对」完成设备配对；没有配对码时可先点「获取配对码指令」让网关生成。")
        }
    }

    // MARK: - 皮肤 / 语音 / 语音助手通道

    private var skinSection: some View {
        Section {
            NavigationLink {
                SkinSettingsView(store: store)
            } label: {
                Label("皮肤", systemImage: "paintpalette")
            }
        } header: {
            Text("皮肤")
        } footer: {
            Text("主题（深色/浅色/跟随系统）、墙纸、全局毛玻璃与灵动岛样式。")
        }
    }

    private var voiceSettingsSection: some View {
        Section {
            NavigationLink {
                VoiceSettingsView(store: store)
            } label: {
                Label("语音设置", systemImage: "waveform.and.mic")
            }
        } header: {
            Text("语音")
        } footer: {
            Text("语音输入/输出、文字转语音、语音转文字与语音唤醒。")
        }
    }

    private var voiceAgentSection: some View {
        Section {
            Picker("通道", selection: $store.settings.voiceAgentChannel) {
                ForEach(VoiceAgentChannel.allCases) { channel in
                    Text(channel.rawValue).tag(channel)
                }
            }
            .pickerStyle(.segmented)
            if store.settings.voiceAgentChannel == .directDeepSeek {
                SecureField("DeepSeek API Key", text: $deepSeekKey)
                    .textContentType(.password)
                Text("直连 DeepSeek 时使用，Key 保存在系统钥匙串（SecureStorage）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { @MainActor in
                    memorySyncMessage = "正在同步电脑记忆…"
                    let base = FileTransferViewModel(settings: store).serverBaseURL
                    guard let url = URL(string: base) else {
                        memorySyncMessage = "同步失败：文件服务地址不可用"
                        return
                    }
                    let service = MemorySyncService.shared
                    var ok = false
                    if let exportData = MemoryProfileStore().exportSnapshot() {
                        ok = await service.uploadPhoneSnapshot(exportData: exportData, baseURL: url)
                    }
                    let snapshot = await service.fetchComputerSnapshot(baseURL: url)
                    if snapshot != nil, ok {
                        memorySyncMessage = "记忆同步完成：档案已上传，电脑快照已拉取"
                    } else if snapshot != nil {
                        memorySyncMessage = "电脑快照已拉取，档案上传未完成（检查电脑文件服务）"
                    } else {
                        memorySyncMessage = ok ? "档案已上传，电脑快照拉取失败" : "同步失败：电脑文件服务不可达"
                    }
                }
            } label: {
                Label("同步电脑记忆", systemImage: "arrow.triangle.2.circlepath")
            }
        } header: {
            Text("语音助手通道")
        } footer: {
            Text("网关=走 OpenClaw 网关回复；直连 DeepSeek=绕过网关直连模型（需 API Key），配合记忆快照离线可用。")
        }
    }

    private var displaySection: some View {
        Section {
            Toggle("显示 Token 用量", isOn: $store.settings.showTokenUsage)
        } header: {
            Text("显示")
        } footer: {
            Text("在助手消息下显示输入/输出 Token 用量，需 Open Responses API 模式。")
        }
    }

    // MARK: - Connection

        private var keyboardSection: some View {
        Section("键盘") {
            NavigationLink {
                KeyboardSettingsPlaceholderView()
            } label: {
                Label("ClawTalk 键盘设置", systemImage: "keyboard.badge.ellipsis")
                    .font(.headline)
            }
            Text("键盘已共享当前 OpenClaw 连接。启用后：选聊天对象 → 粘贴/输入对方的话 → 点 ✨ 生成 AI 回复。")
                .font(.caption)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("1. 打开系统设置", value: "")
                LabeledContent("2. 通用 > 键盘 > 键盘", value: "")
                LabeledContent("3. 添加新键盘", value: "")
                LabeledContent("4. 选择 ClawTalk 键盘", value: "")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

private var connectionSection: some View {
        Section {
            TextField("网关地址", text: $store.settings.gatewayURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("网关令牌", text: $store.gatewayToken)
                .textContentType(.password)

            Picker("接口方式", selection: $store.settings.agentAPIMode) {
                ForEach(AgentAPIMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            NavigationLink {
                GatewayHeadersView(settings: store)
            } label: {
                Label("网关自定义头", systemImage: "bolt.horizontal.circle")
            }

            // HTTP connection test
            Button(action: { testConnection() }) {
                HStack {
                    Text("测试连接")
                    Spacer()
                    switch connectionTestState {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                            .scaleEffect(0.8)
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(store.settings.gatewayURL.isEmpty || connectionTestState == .testing)

            if case .failed(let error) = connectionTestState {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("OpenClaw 网关")
        } footer: {
            switch store.settings.agentAPIMode {
            case .chatCompletions:
                Text("标准聊天接口，兼容所有网关。")
            case .openResponses:
                Text("Open Responses API 模式提供 Token 用量数据，需网关支持（endpoints.responses.enabled）。")
            }
        }
    }

    // MARK: - Display


    // MARK: - 灵动岛 / Live Activity

    /// 灵动岛/锁屏卡片风格与「随 agent 切换」设置。

    // MARK: - Voice Toggle


    // MARK: - TTS Provider


    // MARK: - WeChat Bind

    private var wechatSection: some View {
        Section {
            NavigationLink {
                WechatBindView(settings: store)
            } label: {
                HStack {
                    Label("连接微信 Claw Bot", systemImage: "qrcode")
                    Spacer()
                    if wechatConnected {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("已连接")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    } else {
                        Text("未连接")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("微信")
        } footer: {
            Text("连接后，微信里与 Claw Bot 的对话和电脑端 OpenClaw 同源。")
        }
    }

    // MARK: - Security Info

    // MARK: - Data

    @State private var showClearConfirm = false

    private var dataSection: some View {
        Section {
            Button("清空聊天记录", role: .destructive) {
                showClearConfirm = true
            }
            .confirmationDialog("清空全部聊天记录？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) {
                    ConversationStore.shared.clearAll()
                }
            } message: {
                Text("此操作无法撤销。")
            }
        } header: {
            Text("数据")
        } footer: {
            Text("聊天记录仅存储在本设备，受 iOS 数据保护（静态加密）。")
        }
    }

    /// 日志与诊断
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView(settings: store)
            } label: {
                Label("日志与诊断", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("诊断")
        } footer: {
            Text("查看最近错误日志，并可同步到电脑端 OpenClaw 分析原因。")
        }
    }

    /// 重置新手引导
    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Text("重置新手引导")
            }
        } footer: {
            Text("重置后重新进入新手引导。")
        }
    }

    private func performReset(_ option: ResetOption) {
        store.hasCompletedOnboarding = false
        switch option {
        case .gateway, .full:
            store.settings.gatewayURL = ""
            store.gatewayToken = ""
            store.settings.useWebSocket = false
        case .onboarding:
            break
        }
        store.save()
        if option == .full {
            ChannelStore.shared.channels = [.default]
            ConversationStore.shared.clearAll()
        }
    }

    // MARK: - Connection Test

    private func testConnection() {
        // Save current values before testing
        store.save()
        connectionTestState = .testing

        Task {
            do {
                let baseURL = store.settings.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
                    connectionTestState = .failed(AppErrorText.localized("Invalid gateway URL"))
                    return
                }

                // POST with empty messages — validates auth without triggering a real response.
                // Valid token → 400 (bad request), invalid token → 401.
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let resolvedToken = OpenClawClient.resolveHTTPToken(
                    settingsToken: store.gatewayToken,
                    gatewayURL: store.settings.gatewayURL
                )
                request.setValue("Bearer \(resolvedToken)", forHTTPHeaderField: "Authorization")
                request.httpBody = Data("{\"model\":\"openclaw:main\",\"messages\":[],\"stream\":false}".utf8)
                request.timeoutInterval = 15

                let (_, response) = try await URLSession.shared.data(for: request)

                if let http = response as? HTTPURLResponse {
                    switch http.statusCode {
                    case 200...299, 400:
                        // 400 = auth passed, just invalid request body (empty messages)
                        connectionTestState = .success
                    case 401, 403:
                        connectionTestState = .failed(AppErrorText.httpStatus(http.statusCode))
                        LogCollector.record(module: "测试连接", AppErrorText.httpStatus(http.statusCode))
                    default:
                        connectionTestState = .failed(AppErrorText.httpStatus(http.statusCode))
                        LogCollector.record(module: "测试连接", AppErrorText.httpStatus(http.statusCode))
                    }
                } else {
                    connectionTestState = .failed("Unexpected response")
                }
            } catch let error as URLError {
                switch error.code {
                case .notConnectedToInternet:
                    connectionTestState = .failed("No internet connection")
                case .timedOut:
                    connectionTestState = .failed("Connection timed out. Check the URL and ensure the gateway is running.")
                case .cannotFindHost, .cannotConnectToHost:
                    connectionTestState = .failed("Cannot reach gateway. Check the URL.")
                case .secureConnectionFailed:
                    connectionTestState = .failed("SSL/TLS connection failed. Make sure the gateway uses HTTPS.")
                default:
                    connectionTestState = .failed(error.localizedDescription)
                }
            } catch {
                connectionTestState = .failed(error.localizedDescription)
            }
        }
    }


    // MARK: - Security Info

    private var securitySection: some View {
        Section {
            LabeledContent("Token Storage", value: "iOS Keychain")
            LabeledContent("Transport", value: "HTTPS Only")
            LabeledContent("STT Processing", value: "On-Device")
        } header: {
            Text("安全")
        } footer: {
            Text("API keys and tokens are stored in the iOS Keychain, encrypted at rest. Voice is transcribed on-device — audio never leaves your phone. Agent communication uses HTTPS.")
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            NavigationLink {
                PrivacyPermissionsView()
            } label: {
                Label("隐私与访问权限", systemImage: "hand.raised")
            }
        } header: {
            Text("隐私")
        } footer: {
            Text("查看照片、相机、麦克风、联系人、日历、提醒和通知的授权状态，并可跳转系统设置调整。")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView(settings: store, gatewayConnection: gatewayConnection)
            } label: {
                Label("关于", systemImage: "info.circle")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("App 版本、设备信息与当前网关连接状态。")
        }
    }

    // MARK: - Wake Word Helpers

    /// 清理唤醒词列表：去空白、去空词、按大小写去重；清空后回落到默认词。
    private func sanitizeVoiceWakeWords() {
        var seen = Set<String>()
        var cleaned: [String] = []
        for word in store.settings.voiceWakeWords {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            cleaned.append(trimmed)
        }
        store.settings.voiceWakeWords = cleaned.isEmpty ? ["你好小爪"] : cleaned
    }


    // MARK: - 系统集成（由「系统集成大包」子智能体追加：D 网关管理 / E 证书信任 / F 连接状态 / H 远程终端）

    private var integrationSection: some View {
        Section {
            NavigationLink {
                GatewayProfilesView(store: store, profileStore: gatewayProfileStore)
            } label: {
                Label("网关管理", systemImage: "server.rack")
            }
            NavigationLink {
                CertificateTrustView()
            } label: {
                Label("证书信任", systemImage: "lock.shield")
            }
            NavigationLink {
                GatewayConnectionStatusView(store: store, gatewayConnection: gatewayConnection, nodeConnection: nodeConnection)
            } label: {
                Label("连接状态", systemImage: "antenna.radiowaves.left.and.right")
            }
            NavigationLink {
                TerminalView(store: store)
            } label: {
                Label("远程终端", systemImage: "terminal")
            }
            NavigationLink {
                ScreenStreamView(store: store)
            } label: {
                Label("远程屏幕", systemImage: "display")
            }
            NavigationLink {
                GatewayAutoDiscoveryView(knownGatewayURL: store.settings.gatewayURL) { url in
                    store.settings.gatewayURL = url
                }
            } label: {
                Label("自动发现网关", systemImage: "dot.radiowaves.left.and.right")
            }
            NavigationLink {
                TLSFingerprintProbeView(settings: store)
            } label: {
                Label("TLS 指纹", systemImage: "lock.doc")
            }
            NavigationLink {
                NotificationPreferencesView()
            } label: {
                Label("通知细分", systemImage: "bell.badge")
            }
        } header: {
            Text("系统集成")
        } footer: {
            Text("网关多档案切换、自签证书信任、自动发现、连接诊断与远程命令终端/屏幕。")
        }
    }
}
/// 灵动岛模拟预览卡：按当前风格渲染黑底胶囊卡片（简约/标准/详细）。

/// 键盘设置页：UIViewControllerRepresentable 包 HamsteriOS 完整设置页（工程级整合）。
struct KeyboardSettingsPlaceholderView: View {
    var body: some View {
        KeyboardSettingsHost()
    }
}

private struct KeyboardSettingsHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        KeyboardSettingsHostViewController()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private final class KeyboardSettingsHostViewController: UIViewController {
    private var child: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            let settingsVC = try loadSettingsViewController()
            embed(settingsVC)
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    /// 加载键盘设置页。容器/页面创建失败时抛错，由调用方兜底，绝不导致主程序崩溃。
    private func loadSettingsViewController() throws -> UIViewController {
        HamsterAppDependencyContainer.shared.makeSettingsViewController()
    }

    private func embed(_ settingsVC: UIViewController) {
        addChild(settingsVC)
        settingsVC.view.frame = view.bounds
        settingsVC.view.autoresizingMask = UIView.AutoresizingMask(arrayLiteral: [.flexibleWidth, .flexibleHeight])
        view.addSubview(settingsVC.view)
        settingsVC.didMove(toParent: self)
        child = settingsVC
    }

    private func showFailure(_ reason: String) {
        view.backgroundColor = .systemGroupedBackground
        let label = UILabel()
        label.text = "键盘设置加载失败：\(reason)"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
