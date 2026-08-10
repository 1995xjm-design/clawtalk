import Foundation

enum TTSProvider: String, Codable, CaseIterable, Identifiable {
    case apple = "Apple (Offline)"
    case doubao = "豆包 (Doubao)"

    // 兼容旧数据：未知/已删除的 Provider 回退到 Apple
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TTSProvider(rawValue: raw) ?? .apple
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

struct AppSettings: Codable {
    var gatewayURL: String
    var ttsProvider: TTSProvider
    var sttProvider: STTProvider
    var fusionBackendURL: String
    var openclawVoice: String
    var doubaoVoiceID: String
    var wechatBridgeURL: String
    /// STT 识别语言（复用旧 whisperLanguage 字段名，兼容旧数据）
    var whisperLanguage: String
    var voiceOutputEnabled: Bool
    var voiceInputEnabled: Bool
    var agentAPIMode: AgentAPIMode
    var showTokenUsage: Bool
    var useWebSocket: Bool
    var webSocketPath: String
    /// 朗读是否跟随 iOS 物理静音键（默认开启）
    var followMuteSwitch: Bool
    var hapticsEnabled: Bool
    var appearance: Appearance

    static let defaults = AppSettings(
        gatewayURL: "",
        ttsProvider: .apple,
        sttProvider: .apple,
        fusionBackendURL: "http://127.0.0.1:18890",
        openclawVoice: "BV700_streaming",
        doubaoVoiceID: "zh_female_jitangmei_uranus_bigtts",
        wechatBridgeURL: "",
        whisperLanguage: "zh",
        voiceOutputEnabled: true,
        voiceInputEnabled: true,
        agentAPIMode: .openResponses,
        showTokenUsage: false,
        useWebSocket: false,
        webSocketPath: "/ws",
        followMuteSwitch: true,
        hapticsEnabled: true,
        appearance: .dark
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
            components.path = ""
        } else if let port = Int(normalized) {
            components.port = port
            components.path = ""
        } else {
            components.port = nil
            components.path = normalized.hasPrefix("/") ? normalized : "/\(normalized)"
        }

        return components.url?.absoluteString ?? ""
    }

    init(
        gatewayURL: String,
        ttsProvider: TTSProvider,
        sttProvider: STTProvider = .apple,
        fusionBackendURL: String = "http://127.0.0.1:18890",
        openclawVoice: String = "BV700_streaming",
        doubaoVoiceID: String = "zh_female_jitangmei_uranus_bigtts",
        wechatBridgeURL: String = "",
        whisperLanguage: String = "zh",
        voiceOutputEnabled: Bool,
        voiceInputEnabled: Bool,
        agentAPIMode: AgentAPIMode = .openResponses,
        showTokenUsage: Bool = false,
        useWebSocket: Bool = false,
        webSocketPath: String = "/ws",
        followMuteSwitch: Bool = true,
        hapticsEnabled: Bool = true,
        appearance: Appearance = .dark
    ) {
        self.gatewayURL = gatewayURL
        self.ttsProvider = ttsProvider
        self.sttProvider = sttProvider
        self.fusionBackendURL = fusionBackendURL
        self.openclawVoice = openclawVoice
        self.doubaoVoiceID = doubaoVoiceID
        self.wechatBridgeURL = wechatBridgeURL
        self.whisperLanguage = whisperLanguage
        self.voiceOutputEnabled = voiceOutputEnabled
        self.voiceInputEnabled = voiceInputEnabled
        self.agentAPIMode = agentAPIMode
        self.showTokenUsage = showTokenUsage
        self.useWebSocket = useWebSocket
        self.webSocketPath = webSocketPath
        self.followMuteSwitch = followMuteSwitch
        self.hapticsEnabled = hapticsEnabled
        self.appearance = appearance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gatewayURL = try container.decode(String.self, forKey: .gatewayURL)
        ttsProvider = (try? container.decode(TTSProvider.self, forKey: .ttsProvider)) ?? .apple
        sttProvider = (try? container.decodeIfPresent(STTProvider.self, forKey: .sttProvider)) ?? .apple
        fusionBackendURL = try container.decodeIfPresent(String.self, forKey: .fusionBackendURL) ?? "http://127.0.0.1:18890"
        openclawVoice = try container.decodeIfPresent(String.self, forKey: .openclawVoice) ?? "BV700_streaming"
        doubaoVoiceID = try container.decodeIfPresent(String.self, forKey: .doubaoVoiceID) ?? "zh_female_jitangmei_uranus_bigtts"
        wechatBridgeURL = try container.decodeIfPresent(String.self, forKey: .wechatBridgeURL) ?? ""
        whisperLanguage = try container.decodeIfPresent(String.self, forKey: .whisperLanguage) ?? "zh"
        voiceOutputEnabled = try container.decode(Bool.self, forKey: .voiceOutputEnabled)
        voiceInputEnabled = try container.decode(Bool.self, forKey: .voiceInputEnabled)
        agentAPIMode = try container.decodeIfPresent(AgentAPIMode.self, forKey: .agentAPIMode) ?? .openResponses
        showTokenUsage = try container.decodeIfPresent(Bool.self, forKey: .showTokenUsage) ?? false
        useWebSocket = try container.decodeIfPresent(Bool.self, forKey: .useWebSocket) ?? false
        hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .dark

        // Migrate legacy webSocketPort -> webSocketPath
        if let legacyPort = try container.decodeIfPresent(Int.self, forKey: .webSocketPort) {
            webSocketPath = ":\(legacyPort)"
        } else {
            webSocketPath = try container.decodeIfPresent(String.self, forKey: .webSocketPath) ?? "/ws"
        followMuteSwitch = try container.decodeIfPresent(Bool.self, forKey: .followMuteSwitch) ?? true
        }
    }

    enum CodingKeys: String, CodingKey {
        case gatewayURL, ttsProvider, sttProvider, fusionBackendURL, openclawVoice, doubaoVoiceID
        case wechatBridgeURL, whisperLanguage, voiceOutputEnabled, voiceInputEnabled
        case agentAPIMode, showTokenUsage, useWebSocket
        case webSocketPath, webSocketPort, followMuteSwitch // webSocketPort for legacy decode only
        case hapticsEnabled
        case appearance
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gatewayURL, forKey: .gatewayURL)
        try container.encode(ttsProvider, forKey: .ttsProvider)
        try container.encode(sttProvider, forKey: .sttProvider)
        try container.encode(fusionBackendURL, forKey: .fusionBackendURL)
        try container.encode(openclawVoice, forKey: .openclawVoice)
        try container.encode(doubaoVoiceID, forKey: .doubaoVoiceID)
        try container.encode(wechatBridgeURL, forKey: .wechatBridgeURL)
        try container.encode(whisperLanguage, forKey: .whisperLanguage)
        try container.encode(voiceOutputEnabled, forKey: .voiceOutputEnabled)
        try container.encode(voiceInputEnabled, forKey: .voiceInputEnabled)
        try container.encode(agentAPIMode, forKey: .agentAPIMode)
        try container.encode(showTokenUsage, forKey: .showTokenUsage)
        try container.encode(useWebSocket, forKey: .useWebSocket)
        try container.encode(webSocketPath, forKey: .webSocketPath)
        try container.encode(followMuteSwitch, forKey: .followMuteSwitch)
        try container.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try container.encode(appearance, forKey: .appearance)
        // webSocketPort intentionally not encoded - legacy only
    }
}
