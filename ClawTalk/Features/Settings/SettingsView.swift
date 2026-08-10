import SwiftUI

struct SettingsView: View {
    @Bindable var store: SettingsStore
    var gatewayConnection: GatewayConnection
    @Environment(\.dismiss) private var dismiss
    @AppStorage("clawtalk_wechat_connected") private var wechatConnected = false

    @State private var connectionTestState: ConnectionTestState = .idle
    @State private var previewService: (any SpeechService)?
    @State private var previewPlayback: AudioPlaybackManager?
    @State private var isPreviewing = false
    @State private var previewErrorMessage: String?
    @State private var showResetConfirm = false
    @State private var pendingReset: ResetOption?

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
            keyboardSection
                displaySection
                voiceSection
                ttsSection
                sttSection
                wechatSection
                dataSection
                securitySection
                diagnosticsSection
                resetSection
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                            store.save()
                            dismiss()
                        }
                        .fontWeight(.semibold)
                }
            }
            .alert("语音预览失败", isPresented: Binding(
                get: { previewErrorMessage != nil },
                set: { if !$0 { previewErrorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(previewErrorMessage ?? "")
            }
        }
    }

    // MARK: - Connection

        private var keyboardSection: some View {
        Section {
            Label("AI 聊天回复键盘", systemImage: "keyboard")
                .font(.headline)
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

            Toggle("WebSocket Mode", isOn: $store.settings.useWebSocket)
                .onChange(of: store.settings.useWebSocket) { _, newValue in
                    if newValue {
                        store.settings.showTokenUsage = false
                        // Auto-connect when toggled on
                        if store.isConfigured {
                            store.save()
                            Task {
                                await gatewayConnection.connect(
                                    resolvedURL: store.settings.resolvedWebSocketURL,
                                    token: store.gatewayToken
                                )
                            }
                            // 自动批准设备：发指令让电脑 OpenClaw 批准待连接设备
                            let gw = store.settings.gatewayURL
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            if !gw.isEmpty {
                                let instruction = "请执行 openclaw devices approve --latest 批准待连接的设备，然后回复「已批准」。"
                                Task {
                                    _ = try? await OpenClawClient().chat(
                                        messages: [Message(role: .user, content: instruction)],
                                        gatewayURL: gw,
                                        token: store.gatewayToken
                                    )
                                }
                            }
                        }
                    } else {
                        // Disconnect when toggled off
                        Task {
                            await gatewayConnection.disconnect()
                        }
                    }
                }

            if store.settings.useWebSocket {
                Text("开启后回复实时推送，语音更流畅。首次开启会自动让电脑 OpenClaw 批准设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. 首次开启会自动向电脑 OpenClaw 发送批准指令（devices approve --latest）；")
                        Text("2. 若提示 device is not approved，请到电脑 OpenClaw 执行 openclaw devices approve --latest，或在电脑 OpenClaw 里说「请批准待连接的设备」；")
                        Text("3. 若提示 HTTPS，请在网关地址前使用 https；")
                        Text("4. 仍连不上就关闭此开关，用普通模式（HTTP），功能一样能用。")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } label: {
                    Label("连不上？点这里", systemImage: "questionmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.openClawRed)
                }
            }

            if store.settings.useWebSocket {
                // Live WebSocket connection status
                HStack {
                    Text("连接状态")
                    Spacer()
                    switch gatewayConnection.connectionState {
                    case .connected:
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            Text("已连接")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                    case .connecting:
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("连接中...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    case .disconnected:
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                            Text("未连接")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if gatewayConnection.connectionState == .disconnected {
                    if let error = gatewayConnection.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button("重新连接") {
                        store.save()
                        Task {
                            await gatewayConnection.connect(
                                resolvedURL: store.settings.resolvedWebSocketURL,
                                token: store.gatewayToken
                            )
                        }
                    }
                    .disabled(store.settings.gatewayURL.isEmpty || store.gatewayToken.isEmpty)
                }
            } else {
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
                .disabled(store.settings.gatewayURL.isEmpty || store.gatewayToken.isEmpty || connectionTestState == .testing)

                if case .failed(let error) = connectionTestState {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("OpenClaw 网关")
        } footer: {
            if store.settings.useWebSocket {
                Text("WebSocket enables real-time streaming. Enter a path (e.g. /ws) for tunneled gateways or a port (e.g. 18789) for local connections.")
            } else {
                switch store.settings.agentAPIMode {
                case .chatCompletions:
                    Text("标准聊天接口，兼容所有网关。")
                case .openResponses:
                    Text("Open Responses API provides token usage data. Requires gateway support (endpoints.responses.enabled).")
                }
            }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section {
            Picker("外观", selection: $store.settings.appearance) {
                Text("深色").tag(Appearance.dark)
                Text("浅色").tag(Appearance.light)
            }
            .pickerStyle(.segmented)

            Toggle("Show Token Usage", isOn: $store.settings.showTokenUsage)
                .disabled(store.settings.useWebSocket)
        } header: {
            Text("显示")
        } footer: {
            if store.settings.useWebSocket {
                Text("Token usage is not available in WebSocket mode. Disable WebSocket to see token counts.")
            } else {
                Text("Show input/output token counts under assistant messages. Requires Open Responses API mode.")
            }
        }
    }

    // MARK: - Voice Toggle

    private var voiceSection: some View {
        Section {
            Toggle("语音输入（语音转文字）", isOn: $store.settings.voiceInputEnabled)
            Toggle("语音输出（文字转语音）", isOn: $store.settings.voiceOutputEnabled)
            Toggle("跟随静音键", isOn: $store.settings.followMuteSwitch)
            Toggle("触感反馈", isOn: $store.settings.hapticsEnabled)
        } header: {
            Text("语音")
        } footer: {
            Text("关闭语音输出可纯文字聊天；语音输入使用设备端识别；开启「跟随静音键」后，iPhone 物理静音键开启时朗读自动静音。")
        }
    }

    // MARK: - TTS Provider

    private var ttsSection: some View {
        Section {
            Picker("提供商", selection: $store.settings.ttsProvider) {
                ForEach(TTSProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }

            switch store.settings.ttsProvider {
            case .apple:
                voicePreviewButton
            case .doubao:
                SecureField("豆包 API Key", text: $store.doubaoAPIKey)
                    .textContentType(.password)
                Picker("音色", selection: $store.settings.doubaoVoiceID) {
                    Text("鸡汤妹妹 Hope 2.0").tag("zh_female_jitangmei_uranus_bigtts")
                    Text("温柔淑女 2.0").tag("zh_female_wenroushunv_uranus_bigtts")
                    Text("甜美小源 2.0").tag("zh_female_tianmeixiaoyuan_uranus_bigtts")
                    Text("渊博小叔 2.0").tag("zh_male_yuanboxiaoshu_uranus_bigtts")
                    Text("爽朗少年 Brayan 2.0").tag("zh_male_shaonianzixin_uranus_bigtts")
                }
                TextField("自定义音色 ID", text: $store.settings.doubaoVoiceID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("在豆包语音控制台「音色库」获取音色 ID。中文合成需账号开通。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                voicePreviewButton
            }
        } header: {
            Text("文字转语音")
        } footer: {
            switch store.settings.ttsProvider {
            case .apple:
                Text("使用苹果系统内置语音，免费且支持离线，但自然度一般。")
            case .doubao:
                Text("豆包语音合成大模型（seed-tts-2.0），流式直连，音质自然。")
            }
        }
    }
    // MARK: - STT Model

    private var sttSection: some View {
        Section {
            Picker("提供商", selection: $store.settings.sttProvider) {
                ForEach(STTProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }

            switch store.settings.sttProvider {
            case .apple:
                Picker("识别语言", selection: $store.settings.whisperLanguage) {
                    Text("中文").tag("zh")
                    Text("跟随系统").tag("auto")
                }
                Text("使用 iOS 系统自带识别（支持中文、可离线），无需下载模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .doubao:
                SecureField("豆包 API Key", text: $store.doubaoAPIKey)
                    .textContentType(.password)
                Text("豆包流式语音识别大模型，支持普通话与方言（粤语等），需在豆包语音控制台开通。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("语音转文字")
        } footer: {
            if !store.settings.voiceInputEnabled {
                Text("语音输入已关闭，请在上方开启以使用语音转文字。")
            } else {
                switch store.settings.sttProvider {
                case .apple:
                    Text("使用 iOS 系统识别，设备端离线运行，无需下载模型。")
                case .doubao:
                    Text("音频发送到豆包语音识别服务（网络识别，支持方言）。")
                }
            }
        }
        .disabled(!store.settings.voiceInputEnabled)
    }
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
                request.setValue("Bearer \(store.gatewayToken)", forHTTPHeaderField: "Authorization")
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

    // MARK: - Voice Preview

    private var voicePreviewButton: some View {
        Button(action: { isPreviewing ? stopPreview() : startPreview() }) {
            HStack {
                Text(isPreviewing ? "Stop Preview" : "Preview Voice")
                Spacer()
                if isPreviewing {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.openClawRed)
                } else {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.openClawRed)
                }
            }
        }
        .disabled(previewDisabled)
    }

    private var previewDisabled: Bool {
        switch store.settings.ttsProvider {
        case .doubao:
            return store.doubaoAPIKey.isEmpty
        case .apple:
            return false
        }
    }
    private func startPreview() {
        let sampleText = "你好，这是你的语音预览。"

        let tts: any SpeechService
        switch store.settings.ttsProvider {
        case .doubao:
            tts = DoubaoTTSService(apiKey: store.doubaoAPIKey, voiceID: store.settings.doubaoVoiceID)
        case .apple:
            tts = AppleTTSService()
        }
        previewService = tts
        isPreviewing = true

        switch store.settings.ttsProvider {
        case .apple:
            // Apple TTS 通过 AVSpeechSynthesizer 直接发声。
            // 必须真正消费流，AVSpeechSynthesizer 才会开始朗读。
            Task {
                do {
                    for try await _ in tts.streamSpeech(text: sampleText) {}
                } catch {
                    previewErrorMessage = "语音预览失败：\(error.localizedDescription)"
                }
            }
            // 保持原有 4 秒自动复位逻辑（Apple TTS 无完成回调）
            Task {
                try? await Task.sleep(for: .seconds(4))
                if isPreviewing { isPreviewing = false }
            }
        default:
            // ?? TTS ?? PCM ??
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
                    // 预览失败时明确提示用户，不再静默
                    previewErrorMessage = "语音预览失败：\(error.localizedDescription)"
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

    // MARK: - Security Info

    private var securitySection: some View {
        Section {
            LabeledContent("Token Storage", value: "iOS Keychain")
            LabeledContent("Transport", value: store.settings.useWebSocket ? "WSS + HTTPS" : "HTTPS Only")
            LabeledContent("STT Processing", value: "On-Device")
        } header: {
            Text("安全")
        } footer: {
            Text("API keys and tokens are stored in the iOS Keychain, encrypted at rest. Voice is transcribed on-device — audio never leaves your phone. Agent communication uses HTTPS.")
        }
    }
}
