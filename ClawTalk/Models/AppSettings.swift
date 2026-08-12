import Foundation

enum TTSProvider: String, Codable, CaseIterable, Identifiable {
    case apple = "Apple (Offline)"
    case doubao = "豆包 (Doubao)"
    case edge = "Edge(Microsoft)"

    // 兼容旧数据：未知/已删除的 Provider 回退到 Apple；旧版本 Edge 的 rawValue 是中文描述
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "Edge（晓晓/晓墨/云希/云扬）" {
            self = .edge
        } else {
            self = TTSProvider(rawValue: raw) ?? .apple
        }
    }

    var id: String { rawValue }
}

enum STTProvider: String, Codable, CaseIterable, Identifiable {
    case apple = "Apple (System)"
    case doubao = "豆包 (Doubao)"

    // 兼容旧数据：未知/已删除的 Provider 回退到 Apple
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = STTProvider(rawValue: raw) ?? .apple
    }

    var id: String { rawValue }
}

enum AgentAPIMode: String, Codable, CaseIterable, Identifiable {
    case chatCompletions = "Chat Completions"
    case openResponses = "Open Responses"

    var id: String { rawValue }
}

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case dark
    case light

    /// Migrate unknown/legacy values back to the dark default.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Appearance(rawValue: raw) ?? .dark
    }

    var id: String { rawValue }
}

/// Live Activity（锁屏/灵动岛）卡片风格。
enum LiveActivityStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case minimal = "简约"
    case standard = "标准"
    case detailed = "详细"

    /// 兼容旧数据：未知值回退到「标准」。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LiveActivityStyle(rawValue: raw) ?? .standard
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal: return "简约"
        case .standard: return "标准"
        case .detailed: return "详细"
        }
    }
}

enum HomeThemeSource: String, Codable {
    case systemWallpaper
    case customPhoto
}

struct AppSettings: Codable {
    var gatewayURL: String
    /// 一次性配对令牌（来自 `openclaw qr` 配对码）。首次连接且尚无已配对 deviceToken 时，
    /// 握手走 bootstrap 配对路径（auth.bootstrapToken）；配对成功后网关下发长期 deviceToken。
    /// 内部使用，不在设置页展示。
    var bootstrapToken: String?
    var ttsProvider: TTSProvider
    var sttProvider: STTProvider
    var fusionBackendURL: String
    var openclawVoice: String
    var doubaoVoiceID: String
    var edgeVoiceID: String
    /// 全局语速（-50~50，0=默认；仅 Edge/Apple 生效，豆包不支持）
    var ttsSpeed: Int
    /// 全局音调（-10~10，0=默认；仅 Edge/Apple 生效，豆包不支持）
    var ttsPitch: Int
    var wechatBridgeURL: String
    /// STT 识别语言（复用旧 whisperLanguage 字段名，兼容旧数据）
    var whisperLanguage: String
    var voiceOutputEnabled: Bool
    var voiceInputEnabled: Bool
    var agentAPIMode: AgentAPIMode
    var showTokenUsage: Bool
    var useWebSocket: Bool
    var webSocketPath: String
    var hapticsEnabled: Bool
    var appearance: Appearance
    /// 语音唤醒开关（SIRI 式，仅前台监听）
    var voiceWakeEnabled: Bool
    /// 唤醒词列表（支持多词，任一命中即唤醒）
    var voiceWakeWords: [String]
    /// 兼容旧字段：读/写第一个唤醒词（旧代码与旧数据使用；新 UI 用 voiceWakeWords）
    var voiceWakeWord: String {
        get { voiceWakeWords.first ?? "" }
        set {
            if voiceWakeWords.isEmpty {
                voiceWakeWords = [newValue]
            } else {
                voiceWakeWords[0] = newValue
            }
        }
    }
    /// 语音唤醒命中后进入的频道 ID（UUID 字符串，nil=跟随默认/第一个频道）
    var voiceWakeChannelID: String?
    /// 文件传输助手服务地址（留空则从网关地址自动推断：同主机、端口 8899）
    var fileServerURL: String
    /// 网关自定义请求头（仅附加到 OpenClaw 网关请求）
    var customHeaders: [String: String]
    /// 灵动岛/锁屏卡片风格（简约/标准/详细）
    var liveActivityStyle: LiveActivityStyle
    /// 随 agent 切换：当前频道/agent 变化时自动更新 Live Activity 内容
    var liveActivityFollowAgent: Bool
    /// 语音助手大卡是否显示实时转写/回复文字（默认开启；关闭后大卡只显示状态文字）
    var voiceAssistantShowTranscript: Bool
    // 主页主题（苹果主屏式背景）
    var homeThemeSource: HomeThemeSource
    var homeWallpaperID: Int
    var customWallpaperPath: String?
    var homeBlurStrength: Double

    static let defaults = AppSettings(
        gatewayURL: "",
        ttsProvider: .apple,
        sttProvider: .apple,
        fusionBackendURL: "http://127.0.0.1:18890",
        openclawVoice: "BV700_streaming",
        doubaoVoiceID: "zh_female_jitangmei_uranus_bigtts",
        edgeVoiceID: "zh-CN-XiaoxiaoNeural",
        ttsSpeed: 0,
        ttsPitch: 0,
        wechatBridgeURL: "",
        whisperLanguage: "zh",
        voiceOutputEnabled: true,
        voiceInputEnabled: true,
        agentAPIMode: .openResponses,
        showTokenUsage: false,
        useWebSocket: false,
        webSocketPath: "/ws",
        hapticsEnabled: true,
        appearance: .dark,
        voiceWakeEnabled: false,
        voiceWakeWords: ["你好小爪"],
        fileServerURL: "",
        customHeaders: [:],
        liveActivityStyle: .standard,
        liveActivityFollowAgent: false,
        voiceAssistantShowTranscript: true,
        homeThemeSource: .systemWallpaper,
        homeWallpaperID: 0,
        customWallpaperPath: nil,
        homeBlurStrength: 0.55
    )

    /// Build the full WebSocket URL from the gateway URL + port/path override.
    var resolvedWebSocketURL: String {
        let base = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base) else { return "" }

        let sourceScheme = components.scheme?.lowercased() ?? "https"
        components.scheme = (sourceScheme == "http") ? "ws" : "wss"

        let input = webSocketPath.trimmingCharacters(in: .whitespaces)
        let normalized = input.hasPrefix(":") ? String(input.dropFirst()) : input

        if normalized.isEmpty {
            components.port = 18789
            components.path = "/ws"
        } else if let port = Int(normalized) {
            components.port = port
            components.path = "/ws"
        } else {
            components.path = normalized.hasPrefix("/") ? normalized : "/\(normalized)"
        }

        return components.url?.absoluteString ?? ""
    }

    init(
        gatewayURL: String,
        bootstrapToken: String? = nil,
        ttsProvider: TTSProvider,
        sttProvider: STTProvider = .apple,
        fusionBackendURL: String = "http://127.0.0.1:18890",
        openclawVoice: String = "BV700_streaming",
        doubaoVoiceID: String = "zh_female_jitangmei_uranus_bigtts",
        edgeVoiceID: String = "zh-CN-XiaoxiaoNeural",
        ttsSpeed: Int = 0,
        ttsPitch: Int = 0,
        wechatBridgeURL: String = "",
        whisperLanguage: String = "zh",
        voiceOutputEnabled: Bool,
        voiceInputEnabled: Bool,
        agentAPIMode: AgentAPIMode = .openResponses,
        showTokenUsage: Bool = false,
        useWebSocket: Bool = false,
        webSocketPath: String = "/ws",
        hapticsEnabled: Bool = true,
        appearance: Appearance = .dark,
        voiceWakeEnabled: Bool = false,
        voiceWakeWord: String = "你好小爪",
        voiceWakeWords: [String]? = nil,
        voiceWakeChannelID: String? = nil,
        fileServerURL: String = "",
        customHeaders: [String: String] = [:],
        liveActivityStyle: LiveActivityStyle = .standard,
        liveActivityFollowAgent: Bool = false,
        voiceAssistantShowTranscript: Bool = true,
        homeThemeSource: HomeThemeSource = .systemWallpaper,
        homeWallpaperID: Int = 0,
        customWallpaperPath: String? = nil,
        homeBlurStrength: Double = 0.55
    ) {
        self.gatewayURL = gatewayURL
        self.bootstrapToken = bootstrapToken
        self.ttsProvider = ttsProvider
        self.sttProvider = sttProvider
        self.fusionBackendURL = fusionBackendURL
        self.openclawVoice = openclawVoice
        self.doubaoVoiceID = doubaoVoiceID
        self.edgeVoiceID = edgeVoiceID
        self.ttsSpeed = ttsSpeed
        self.ttsPitch = ttsPitch
        self.wechatBridgeURL = wechatBridgeURL
        self.whisperLanguage = whisperLanguage
        self.voiceOutputEnabled = voiceOutputEnabled
        self.voiceInputEnabled = voiceInputEnabled
        self.agentAPIMode = agentAPIMode
        self.showTokenUsage = showTokenUsage
        self.useWebSocket = useWebSocket
        self.webSocketPath = webSocketPath
        self.hapticsEnabled = hapticsEnabled
        self.appearance = appearance
        self.voiceWakeEnabled = voiceWakeEnabled
        self.voiceWakeWords = voiceWakeWords ?? [voiceWakeWord]
        self.voiceWakeChannelID = voiceWakeChannelID
        self.fileServerURL = fileServerURL
        self.customHeaders = customHeaders
        self.liveActivityStyle = liveActivityStyle
        self.liveActivityFollowAgent = liveActivityFollowAgent
        self.voiceAssistantShowTranscript = voiceAssistantShowTranscript
        self.homeThemeSource = homeThemeSource
        self.homeWallpaperID = homeWallpaperID
        self.customWallpaperPath = customWallpaperPath
        self.homeBlurStrength = homeBlurStrength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gatewayURL = try container.decode(String.self, forKey: .gatewayURL)
        if let raw = try container.decodeIfPresent(String.self, forKey: .bootstrapToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            bootstrapToken = raw
        } else {
            bootstrapToken = nil
        }
        ttsProvider = (try? container.decode(TTSProvider.self, forKey: .ttsProvider)) ?? .apple
        sttProvider = (try? container.decodeIfPresent(STTProvider.self, forKey: .sttProvider)) ?? .apple
        fusionBackendURL = try container.decodeIfPresent(String.self, forKey: .fusionBackendURL) ?? "http://127.0.0.1:18890"
        openclawVoice = try container.decodeIfPresent(String.self, forKey: .openclawVoice) ?? "BV700_streaming"
        doubaoVoiceID = try container.decodeIfPresent(String.self, forKey: .doubaoVoiceID) ?? "zh_female_jitangmei_uranus_bigtts"
        edgeVoiceID = try container.decodeIfPresent(String.self, forKey: .edgeVoiceID) ?? "zh-CN-XiaoxiaoNeural"
        ttsSpeed = try container.decodeIfPresent(Int.self, forKey: .ttsSpeed) ?? 0
        ttsPitch = try container.decodeIfPresent(Int.self, forKey: .ttsPitch) ?? 0
        wechatBridgeURL = try container.decodeIfPresent(String.self, forKey: .wechatBridgeURL) ?? ""
        whisperLanguage = try container.decodeIfPresent(String.self, forKey: .whisperLanguage) ?? "zh"
        voiceOutputEnabled = try container.decode(Bool.self, forKey: .voiceOutputEnabled)
        voiceInputEnabled = try container.decode(Bool.self, forKey: .voiceInputEnabled)
        agentAPIMode = try container.decodeIfPresent(AgentAPIMode.self, forKey: .agentAPIMode) ?? .openResponses
        showTokenUsage = try container.decodeIfPresent(Bool.self, forKey: .showTokenUsage) ?? false
        useWebSocket = try container.decodeIfPresent(Bool.self, forKey: .useWebSocket) ?? false
        hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .dark
        voiceWakeEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceWakeEnabled) ?? false
        if let words = try container.decodeIfPresent([String].self, forKey: .voiceWakeWords), !words.isEmpty {
            voiceWakeWords = words
        } else if let legacyWord = try container.decodeIfPresent(String.self, forKey: .voiceWakeWord), !legacyWord.isEmpty {
            voiceWakeWords = [legacyWord]
        } else {
            voiceWakeWords = ["你好小爪"]
        }
        voiceWakeChannelID = try container.decodeIfPresent(String.self, forKey: .voiceWakeChannelID)
        fileServerURL = try container.decodeIfPresent(String.self, forKey: .fileServerURL) ?? ""
        customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        liveActivityStyle = try container.decodeIfPresent(LiveActivityStyle.self, forKey: .liveActivityStyle) ?? .standard
        liveActivityFollowAgent = try container.decodeIfPresent(Bool.self, forKey: .liveActivityFollowAgent) ?? false
        voiceAssistantShowTranscript = try container.decodeIfPresent(Bool.self, forKey: .voiceAssistantShowTranscript) ?? true
        homeThemeSource = (try? container.decodeIfPresent(HomeThemeSource.self, forKey: .homeThemeSource)) ?? .systemWallpaper
        homeWallpaperID = try container.decodeIfPresent(Int.self, forKey: .homeWallpaperID) ?? 0
        customWallpaperPath = try container.decodeIfPresent(String.self, forKey: .customWallpaperPath)
        homeBlurStrength = try container.decodeIfPresent(Double.self, forKey: .homeBlurStrength) ?? 0.55

        // Migrate legacy webSocketPort -> webSocketPath
        if let legacyPort = try container.decodeIfPresent(Int.self, forKey: .webSocketPort) {
            webSocketPath = ":\(legacyPort)"
        } else {
            webSocketPath = try container.decodeIfPresent(String.self, forKey: .webSocketPath) ?? "/ws"
        }
    }

    enum CodingKeys: String, CodingKey {
        case gatewayURL, bootstrapToken
        case ttsProvider, sttProvider, fusionBackendURL, openclawVoice, doubaoVoiceID, edgeVoiceID
        case ttsSpeed, ttsPitch
        case wechatBridgeURL, whisperLanguage, voiceOutputEnabled, voiceInputEnabled
        case agentAPIMode, showTokenUsage, useWebSocket
        case webSocketPath, webSocketPort // webSocketPort for legacy decode only
        case hapticsEnabled
        case appearance
        case voiceWakeEnabled
        case voiceWakeWord // legacy decode/encode key
        case voiceWakeWords
        case voiceWakeChannelID
        case fileServerURL
        case customHeaders
        case liveActivityStyle
        case liveActivityFollowAgent
        case voiceAssistantShowTranscript
        case homeThemeSource, homeWallpaperID, customWallpaperPath, homeBlurStrength
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gatewayURL, forKey: .gatewayURL)
        try container.encodeIfPresent(bootstrapToken, forKey: .bootstrapToken)
        try container.encode(ttsProvider, forKey: .ttsProvider)
        try container.encode(sttProvider, forKey: .sttProvider)
        try container.encode(fusionBackendURL, forKey: .fusionBackendURL)
        try container.encode(openclawVoice, forKey: .openclawVoice)
        try container.encode(doubaoVoiceID, forKey: .doubaoVoiceID)
        try container.encode(edgeVoiceID, forKey: .edgeVoiceID)
        try container.encode(ttsSpeed, forKey: .ttsSpeed)
        try container.encode(ttsPitch, forKey: .ttsPitch)
        try container.encode(wechatBridgeURL, forKey: .wechatBridgeURL)
        try container.encode(whisperLanguage, forKey: .whisperLanguage)
        try container.encode(voiceOutputEnabled, forKey: .voiceOutputEnabled)
        try container.encode(voiceInputEnabled, forKey: .voiceInputEnabled)
        try container.encode(agentAPIMode, forKey: .agentAPIMode)
        try container.encode(showTokenUsage, forKey: .showTokenUsage)
        try container.encode(useWebSocket, forKey: .useWebSocket)
        try container.encode(webSocketPath, forKey: .webSocketPath)
        try container.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(voiceWakeEnabled, forKey: .voiceWakeEnabled)
        try container.encode(voiceWakeWords, forKey: .voiceWakeWords)
        try container.encode(voiceWakeWord, forKey: .voiceWakeWord) // 兼容旧读取方：写入第一个词
        try container.encodeIfPresent(voiceWakeChannelID, forKey: .voiceWakeChannelID)
        try container.encode(fileServerURL, forKey: .fileServerURL)
        try container.encode(customHeaders, forKey: .customHeaders)
        try container.encode(liveActivityStyle, forKey: .liveActivityStyle)
        try container.encode(liveActivityFollowAgent, forKey: .liveActivityFollowAgent)
        try container.encode(voiceAssistantShowTranscript, forKey: .voiceAssistantShowTranscript)
        try container.encode(homeThemeSource, forKey: .homeThemeSource)
        try container.encode(homeWallpaperID, forKey: .homeWallpaperID)
        try container.encodeIfPresent(customWallpaperPath, forKey: .customWallpaperPath)
        try container.encode(homeBlurStrength, forKey: .homeBlurStrength)
        // webSocketPort intentionally not encoded - legacy only
    }
}
