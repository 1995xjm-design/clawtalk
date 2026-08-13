import PhotosUI
import SwiftUI

/// 唤醒词编辑行：UUID 稳定 id（ForEach 删除/编辑不会因 index 越界崩溃）。
private struct WakeWordEdit: Identifiable, Equatable {
    let id = UUID()
    var word: String
}

struct SettingsView: View {
    @Bindable var store: SettingsStore
    var gatewayConnection: GatewayConnection
    var nodeConnection: NodeConnection? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("clawtalk_wechat_connected") private var wechatConnected = false

    @State private var connectionTestState: ConnectionTestState = .idle
    @State private var previewService: (any SpeechService)?
    @State private var previewPlayback: AudioPlaybackManager?
    @State private var isPreviewing = false
    @State private var previewErrorMessage: String?
    @State private var showResetConfirm = false
    @State private var pendingReset: ResetOption?
    @State private var gatewayProfileStore = GatewayProfileStore()
    @State private var showAddWakeWord = false
    @State private var newWakeWord = ""
    @State private var showScanPairing = false
    @State private var scanNotice: String?
    @State private var rescanToken = 0
    @State private var pairingMessage: String?
    @State private var showPairingResult = false
    @State private var showThemePhotoPicker = false
    @State private var themePhotoItem: PhotosPickerItem?
    @State private var wakeWordEdits: [WakeWordEdit] = []


    // MARK: - 唤醒词编辑（本地 UUID 列表，避免 ForEach(id: \.offset) 删除/编辑越界崩溃）

    private func syncWakeWordEdits() {
        wakeWordEdits = store.settings.voiceWakeWords.map { WakeWordEdit(word: $0) }
    }

    private func commitWakeWords() {
        store.settings.voiceWakeWords = wakeWordEdits.map(\.word)
        store.save()
    }

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

    private func removeWakeWord(_ edit: WakeWordEdit) {
        wakeWordEdits.removeAll { $0.id == edit.id }
        commitWakeWords()
        hotReloadVoiceWakeKeywords()
    }

    private func addWakeWord(_ word: String) {
        wakeWordEdits.append(WakeWordEdit(word: word))
        commitWakeWords()
        hotReloadVoiceWakeKeywords()
    }

    private func resetWakeWords() {
        wakeWordEdits = [WakeWordEdit(word: "你好小爪")]
        commitWakeWords()
        hotReloadVoiceWakeKeywords()
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
            keyboardSection
                displaySection
                appearanceSection
                liveActivitySection
                voiceSection
                ttsSection
                sttSection
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
            .alert("语音预览失败", isPresented: Binding(
                get: { previewErrorMessage != nil },
                set: { if !$0 { previewErrorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(previewErrorMessage ?? "")
            }
            .alert("添加唤醒词", isPresented: $showAddWakeWord) {
                TextField("唤醒词", text: $newWakeWord)
                Button("添加") {
                    let word = newWakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !word.isEmpty {
                        addWakeWord(word)
                    }
                    newWakeWord = ""
                }
                Button("取消", role: .cancel) {
                    newWakeWord = ""
                }
            } message: {
                Text("说出该词即可唤醒（建议 2-4 个字）。")
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
    // MARK: - 外观（主页主题：内置壁纸/自定义照片/模糊强度）

    private var appearanceSection: some View {
        Section("外观") {
            // 内置壁纸（横排缩略图，点选即应用）
            HStack(spacing: 12) {
                // 无壁纸（默认纯色，跟随深浅色）
                Button {
                    store.settings.homeThemeSource = .noWallpaper
                    store.settings.homeWallpaperID = 0
                    store.settings.homeWallpaperChosen = false
                    store.settings.customWallpaperPath = nil
                    store.save()
                } label: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.systemGroupedBackground))
                        .frame(width: 54, height: 96)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    store.settings.homeThemeSource == .noWallpaper
                                        ? Color.accentColor : Color(.separator).opacity(0.5),
                                    lineWidth: store.settings.homeThemeSource == .noWallpaper ? 2.5 : 1
                                )
                        )
                        .overlay(
                            Image(systemName: "rectangle.on.rectangle.slash")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("无壁纸（默认纯色）")
                ForEach(0..<HomeWallpaper.builtinCount, id: \.self) { id in
                    Button {
                        store.settings.homeThemeSource = .systemWallpaper
                        store.settings.homeWallpaperID = id
                        store.settings.homeWallpaperChosen = true
                        store.save()
                    } label: {
                        if let image = HomeWallpaper.builtinImage(id: id, size: CGSize(width: 54, height: 96)) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 54, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            store.settings.homeThemeSource == .systemWallpaper && store.settings.homeWallpaperID == id
                                                ? Color.accentColor : Color.clear,
                                            lineWidth: 2.5
                                        )
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Button {
                showThemePhotoPicker = true
            } label: {
                Label(
                    store.settings.homeThemeSource == .customPhoto ? "更换自定义壁纸" : "从相册选择壁纸",
                    systemImage: "photo.on.rectangle"
                )
            }
            .photosPicker(isPresented: $showThemePhotoPicker, selection: $themePhotoItem, matching: .images)
            .onChange(of: themePhotoItem) { _, item in
                guard let item else { return }
                Task {
                    defer { themePhotoItem = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    if let path = HomeWallpaper.saveCustomPhoto(data) {
                        store.settings.customWallpaperPath = path
                        store.settings.homeThemeSource = .customPhoto
                        store.settings.homeWallpaperChosen = true
                        store.save()
                    }
                }
            }
            HStack {
                Text("模糊强度")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Slider(value: $store.settings.homeBlurStrength, in: 0.1...1.0)
            }
            .onChange(of: store.settings.homeBlurStrength) { _, _ in
                store.save()
            }
            Button("恢复默认壁纸") {
                store.settings.homeThemeSource = .noWallpaper
                store.settings.homeWallpaperID = 0
                store.settings.homeWallpaperChosen = false
                store.settings.customWallpaperPath = nil
                store.save()
            }
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

    private var displaySection: some View {
        Section {
            Picker("外观", selection: $store.settings.appearance) {
                Text("深色").tag(Appearance.dark)
                Text("浅色").tag(Appearance.light)
            }
            .pickerStyle(.segmented)

            Toggle("显示 Token 用量", isOn: $store.settings.showTokenUsage)

            HStack {
                Text("全局毛玻璃")
                Spacer()
                Button {
                    store.settings.globalGlassEnabled.toggle()
                    store.save()
                } label: {
                    Text(store.settings.globalGlassEnabled ? "已开启" : "关闭")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                store.settings.globalGlassEnabled
                                    ? Color.green.opacity(0.18)
                                    : Color(.systemGray5)
                            )
                        )
                        .foregroundStyle(store.settings.globalGlassEnabled ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("显示")
        } footer: {
            Text("在助手消息下显示输入/输出 Token 用量，需 Open Responses API 模式。开启全局毛玻璃后，主页与频道背景启用磨砂材质（配合壁纸效果最佳）。")
        }
    }

    // MARK: - 灵动岛 / Live Activity

    /// 灵动岛/锁屏卡片风格与「随 agent 切换」设置。
    private var liveActivitySection: some View {
        Section {
            Picker("风格", selection: $store.settings.liveActivityStyle) {
                ForEach(LiveActivityStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: store.settings.liveActivityStyle) { _, _ in
                refreshLiveActivityStyle()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("样式预览（\(store.settings.liveActivityStyle.displayName)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LiveActivityPreviewCard(
                    style: store.settings.liveActivityStyle,
                    channelName: "语音助手",
                    statusText: "正在聆听…"
                )
            }
            .padding(.vertical, 4)

            Toggle("随 agent 切换", isOn: $store.settings.liveActivityFollowAgent)
                .onChange(of: store.settings.liveActivityFollowAgent) { _, _ in
                    refreshLiveActivityStyle()
                }
        } header: {
            Text("灵动岛")
        } footer: {
            Text("免提对话期间的锁屏/灵动岛卡片风格：简约=仅状态；标准=频道名+状态；详细=图标+频道名+状态两行。开启「随 agent 切换」后，切换频道/agent 时卡片自动改为新 agent 名称。Live Activity 本地更新仅在 App 前台/后台任务期间生效（未配置 APNs 推送更新）。")
        }
    }

    // MARK: - Voice Toggle

    private var voiceSection: some View {
        Section {
            Toggle("语音输入（语音转文字）", isOn: $store.settings.voiceInputEnabled)
            Toggle("语音输出（文字转语音）", isOn: $store.settings.voiceOutputEnabled)
            Toggle("语音助手显示实时转写", isOn: $store.settings.voiceAssistantShowTranscript)
            Toggle("触感反馈", isOn: $store.settings.hapticsEnabled)
            Toggle("语音唤醒", isOn: $store.settings.voiceWakeEnabled)
            if store.settings.voiceWakeEnabled {
                Picker("唤醒后进入的频道", selection: $store.settings.voiceWakeChannelID) {
                    Text("自动（默认频道）").tag(nil as String?)
                    ForEach(ChannelStore.shared.channels) { channel in
                        Text(channel.name).tag(channel.id.uuidString as String?)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($wakeWordEdits) { $edit in
                        HStack(spacing: 8) {
                            TextField("唤醒词", text: $edit.word)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button {
                                removeWakeWord(edit)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Button("添加词") {
                            newWakeWord = ""
                            showAddWakeWord = true
                        }
                        Spacer()
                        Button("重置默认") {
                            resetWakeWords()
                        }
                    }
                    .font(.subheadline)
                }
                .onAppear(perform: syncWakeWordEdits)
                .onChange(of: wakeWordEdits) { _, _ in
                    commitWakeWords()
                }
                Text("每个词一行，任一唤醒词命中即进入免提对话；唤醒后进入你选的频道。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("语音")
        } footer: {
            Text("关闭语音输出可纯文字聊天；语音输入使用设备端识别；语音唤醒需麦克风与语音识别权限；开启后前台/后台均可唤醒。")
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
            case .edge:
                Picker("音色", selection: $store.settings.edgeVoiceID) {
                    Text("晓晓（女）").tag("zh-CN-XiaoxiaoNeural")
                    Text("小艺").tag("zh-CN-XiaoyiNeural")
                    Text("云希（男）").tag("zh-CN-YunxiNeural")
                    Text("云扬（男）").tag("zh-CN-YunyangNeural")
                    Text("云健（男）").tag("zh-CN-YunjianNeural")
                    Text("云夏（女）").tag("zh-CN-YunxiaNeural")
                    Text("晓曼（粤语·女）").tag("zh-HK-HiuMaanNeural")
                    Text("云龙（粤语·男）").tag("zh-HK-WanLungNeural")
                    Text("晓佳（粤语·女）").tag("zh-HK-HiuGaaiNeural")
                    Text("晓臻（台湾·女）").tag("zh-TW-HsiaoChenNeural")
                }
                Text("微软 Edge 免费接口，无需 API Key。晓墨（zh-CN-XiaomoNeural）已被微软移除（实测 Unsupported voice），用同为女声的「小艺」替代。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                voicePreviewButton
            }

            if store.settings.ttsProvider != .doubao {
                speedSlider
                pitchSlider
            }
        } header: {
            Text("文字转语音")
        } footer: {
            switch store.settings.ttsProvider {
            case .apple:
                Text("使用苹果系统内置语音，免费且支持离线，但自然度一般。")
            case .doubao:
                Text("豆包语音合成大模型（seed-tts-2.0），流式直连，音质自然。")
            case .edge:
                Text("微软 Edge 免费接口（非官方），无需 API Key；24kHz 高音质，需联网。")
            }
        }
    }

    private var ttsSpeedBinding: Binding<Double> {
        Binding(
            get: { Double(store.settings.ttsSpeed) },
            set: { store.settings.ttsSpeed = Int($0.rounded()) }
        )
    }

    private var ttsPitchBinding: Binding<Double> {
        Binding(
            get: { Double(store.settings.ttsPitch) },
            set: { store.settings.ttsPitch = Int($0.rounded()) }
        )
    }

    private var speedSlider: some View {
        HStack {
            Text("语速")
                .frame(width: 44, alignment: .leading)
            Slider(value: ttsSpeedBinding, in: -50...50, step: 5)
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
            Slider(value: ttsPitchBinding, in: -10...10, step: 1)
            Text(pitchValueText)
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var speedValueText: String {
        store.settings.ttsSpeed > 0 ? "+\(store.settings.ttsSpeed)" : "\(store.settings.ttsSpeed)"
    }

    private var pitchValueText: String {
        store.settings.ttsPitch > 0 ? "+\(store.settings.ttsPitch)" : "\(store.settings.ttsPitch)"
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

    /// 灵动岛风格/「随 agent 切换」变更后，用当前卡片状态按新风格重刷。
    private func refreshLiveActivityStyle() {
        store.save()
        ClawTalkLiveActivity.update(
            statusText: "免提对话",
            icon: "💬"
        )
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
        case .edge:
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
            tts = AppleTTSService(speed: store.settings.ttsSpeed, pitch: store.settings.ttsPitch)
        case .edge:
            tts = EdgeTTSService(voiceID: store.settings.edgeVoiceID, speed: store.settings.ttsSpeed, pitch: store.settings.ttsPitch)
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
                    let message = "语音预览失败：\(AppErrorText.localized(error.localizedDescription))"
                    previewErrorMessage = message
                    LogCollector.record(module: "语音预览", message)
                }
            }
            // 保持原有 4 秒自动复位逻辑（Apple TTS 无完成回调）
            Task {
                try? await Task.sleep(for: .seconds(4))
                if isPreviewing { isPreviewing = false }
            }
        default:
            // 非 Apple TTS 走 PCM 播放
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
private struct LiveActivityPreviewCard: View {
    let style: LiveActivityStyle
    let channelName: String
    let statusText: String

    var body: some View {
        Group {
            switch style {
            case .minimal:
                Text(statusText)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            case .standard:
                Text("\(channelName) · \(statusText)")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            case .detailed:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("💬")
                        Text(channelName)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .accessibilityLabel("灵动岛样式预览：\(style.displayName)")
    }
}

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
        let container = HamsterAppDependencyContainer()
        let settingsVC = container.makeSettingsViewController()
        addChild(settingsVC)
        settingsVC.view.frame = view.bounds
        settingsVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(settingsVC.view)
        settingsVC.didMove(toParent: self)
        child = settingsVC
    }
}
        .navigationTitle("键盘设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
