import SwiftUI

/// 唤醒词编辑行：UUID 稳定 id（ForEach 删除/编辑不会因 index 越界崩溃）。
private struct WakeWordEdit: Identifiable, Equatable {
    let id = UUID()
    var word: String
}

/// 语音助手通道网关探测：复用 DiagnosticsView 的鉴权检测逻辑
/// （resolveHTTPToken 解析令牌 + Bearer 探测 /v1/models，404 回退 /health），
/// 401/429/超时给明确中文提示。设置页与语音大卡共用。
enum VoiceAgentGatewayProbe {
    struct ProbeResult: Equatable {
        let success: Bool
        let message: String
    }

    static func run(settings: SettingsStore) async -> ProbeResult {
        let result = await ConnectionDiagnostics.runAuth(settings: settings)
        var message = result.detail
        if result.detail.contains("HTTP 429") {
            message = "请求过于频繁（HTTP 429）：网关限流，请稍后再试。"
        } else if result.detail.contains("HTTP 408") {
            message = "请求超时（HTTP 408）：请检查网关负载或稍后重试。"
        }
        return ProbeResult(success: result.success, message: message)
    }
}

/// 语音助手通道「测试网关连接」按钮状态（设置页与语音大卡共用）。
enum VoiceAgentGatewayTestState: Equatable {
    case idle
    case testing
    case success
    case failed(String)
}

/// 语音设置页：语音开关、文字转语音、语音转文字（原设置页三块原样搬入）。
struct VoiceSettingsView: View {
    @Bindable var store: SettingsStore

    @State private var previewService: (any SpeechService)?
    @State private var previewPlayback: AudioPlaybackManager?
    @State private var isPreviewing = false
    @State private var previewErrorMessage: String?
    @State private var showAddWakeWord = false
    @State private var newWakeWord = ""
    @State private var wakeWordEdits: [WakeWordEdit] = []
    @State private var gatewayChannelTestState: VoiceAgentGatewayTestState = .idle

    var body: some View {
        NavigationStack {
            Form {
                voiceAgentChannelSection
                voiceSection
                ttsSection
                sttSection
            }
            .navigationTitle("语音设置")
            .navigationBarTitleDisplayMode(.inline)
            .alert("语音预览失败", isPresented: Binding(
                get: { previewErrorMessage != nil },
                set: { if !$0 { previewErrorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(previewErrorMessage ?? "")
            }
            .sheet(isPresented: $showAddWakeWord) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("唤醒词", text: $newWakeWord)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } footer: {
                            Text("说出该词即可唤醒（建议 2-4 个字）。")
                        }
                    }
                    .navigationTitle("添加唤醒词")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") {
                                newWakeWord = ""
                                showAddWakeWord = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("添加") {
                                let word = newWakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !word.isEmpty {
                                    addWakeWord(word)
                                }
                                newWakeWord = ""
                                showAddWakeWord = false
                            }
                            .disabled(newWakeWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.height(220)])
            }
        }
    }

    // MARK: - 语音助手通道连接

    /// 语音助手通道连接区：网关模式下显示当前网关地址/令牌状态 + 测试按钮
    /// （复用 DiagnosticsView 检测逻辑，401/429/超时给明确中文提示）。
    private var voiceAgentChannelSection: some View {
        Section {
            LabeledContent("通道", value: voiceAgentChannelLabel)
            switch store.settings.voiceAgentChannel {
            case .gateway:
                LabeledContent("网关地址", value: store.settings.gatewayURL.isEmpty ? "未配置" : store.settings.gatewayURL)
                    .lineLimit(1)
                    .truncationMode(.middle)
                LabeledContent("网关令牌", value: store.gatewayToken.isEmpty ? "未设置" : "已设置")
                Button(action: { testGatewayChannel() }) {
                    HStack {
                        Text("测试网关连接")
                        Spacer()
                        switch gatewayChannelTestState {
                        case .idle:
                            Image(systemName: "bolt.horizontal.circle")
                                .foregroundStyle(.openClawRed)
                        case .testing:
                            ProgressView().scaleEffect(0.8)
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failed:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .disabled(store.settings.gatewayURL.isEmpty || gatewayChannelTestState == .testing)
                if case .failed(let message) = gatewayChannelTestState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if case .success = gatewayChannelTestState {
                    Text("网关连接正常：地址可达，令牌有效。")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            case .directDeepSeek:
                let hasKey = !(SecureStorage.shared.getString("deepseek_api_key") ?? "").isEmpty
                LabeledContent("DeepSeek API Key", value: hasKey ? "已配置" : "未配置")
                Text("直连 DeepSeek 的 API Key 在「设置 > 语音助手通道」填写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("语音助手通道")
        } footer: {
            Text("语音助手回复走网关（OpenClaw）还是直连 DeepSeek；「测试网关连接」复用诊断页检测逻辑，401/429/超时会给出明确提示。")
        }
    }

    private var voiceAgentChannelLabel: String {
        switch store.settings.voiceAgentChannel {
        case .gateway: return "网关"
        case .directDeepSeek: return "直连 DeepSeek"
        }
    }

    private func testGatewayChannel() {
        store.save()
        gatewayChannelTestState = .testing
        Task {
            let result = await VoiceAgentGatewayProbe.run(settings: store)
            gatewayChannelTestState = result.success ? .success : .failed(result.message)
        }
    }

    // MARK: - 唤醒词编辑（本地 UUID 列表，避免 ForEach(id: \.offset) 删除/编辑越界崩溃）

    private func syncWakeWordEdits() {
        wakeWordEdits = store.settings.voiceWakeWords.map { WakeWordEdit(word: $0) }
    }

    private func commitWakeWords() {
        store.settings.voiceWakeWords = wakeWordEdits.map {
            $0.word.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        store.save()
    }

    /// 唤醒词列表变更且引擎正在监听时热更新（主 App 只监听开关变化，词表变化需此处补齐）。
    private func hotReloadVoiceWakeKeywords() {
        guard store.settings.voiceWakeEnabled else { return }
        let words = store.settings.voiceWakeWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        // 引擎当前未监听（对讲占用/看门狗尚未拉起）：词表已持久化，
        // 下次 startVoiceWakeIfNeeded 会用新词表，不在此强拉麦克风。
        guard VoiceWakeCapability.shared.isListening else { return }
        Task { @MainActor in
            VoiceWakeCapability.shared.stopListening()
            do {
                _ = try await VoiceWakeCapability.shared.setConfig(keywords: words, enabled: true, locale: "zh-CN")
            } catch {
                LogCollector.record(module: "语音唤醒", "唤醒词热更新失败：\(AppErrorText.localized(error.localizedDescription))")
            }
        }
    }

    private func removeWakeWord(_ edit: WakeWordEdit) {
        wakeWordEdits.removeAll { $0.id == edit.id }
        commitWakeWords()
        hotReloadVoiceWakeKeywords()
    }

    private func addWakeWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let alreadyExists = wakeWordEdits.contains {
            $0.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed.lowercased()
        }
        guard !alreadyExists else { return }
        wakeWordEdits.append(WakeWordEdit(word: trimmed))
        commitWakeWords()
        hotReloadVoiceWakeKeywords()
    }

    private func resetWakeWords() {
        wakeWordEdits = [WakeWordEdit(word: "你好小爪")]
        commitWakeWords()
        hotReloadVoiceWakeKeywords()
    }

    // MARK: - 语音

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

    // MARK: - 试听

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
}