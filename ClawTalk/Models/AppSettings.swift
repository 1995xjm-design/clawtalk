import Foundation

enum TTSProvider: String, Codable, CaseIterable, Identifiable {
    case elevenlabs = "ElevenLabs"
    case openai = "OpenAI"
    case openclaw = "OpenClaw Backend"
    case minimax = "MiniMax"
    case apple = "Apple (Offline)"
    // Kokoro 本地语音服务由 FUSION-009 并行任务补齐实现，此处仅预留枚举值
    case kokoro = "Kokoro (Local)"

    var id: String { rawValue }
}

enum STTProvider: String, Codable, CaseIterable, Identifiable {
    case local = "Local Whisper"
    case openclaw = "OpenClaw Backend"

    var id: String { rawValue }
}

enum AgentAPIMode: String, Codable, CaseIterable, Identifiable {
    case chatCompletions = "Chat Completions"
    case openResponses = "Open Responses"

    var id: String { rawValue }
}

enum WhisperModelSize: String, Codable, CaseIterable, Identifiable {
    case small = "small"
    case largeTurbo = "large-v3_turbo"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Migrate old "large-v3-turbo" to "large-v3_turbo"
        if raw == "large-v3-turbo" {
            self = .largeTurbo
        } else if let value = WhisperModelSize(rawValue: raw) {
            self = value
        } else {
            self = .small
        }
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small (250 MB, 中英多语言, faster)"
        case .largeTurbo: return "Large Turbo (1.6 GB, best quality)"
        }
    }
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
    var elevenLabsVoiceID: String
    var openAIVoice: String
    var fusionBackendURL: String
    var openclawVoice: String
    var minimaxGroupID: String
    var minimaxAPIKey: String
    var minimaxDomain: String
    var minimaxVoiceID: String
    var wechatBridgeURL: String
    var whisperModelSize: WhisperModelSize
    var whisperLanguage: String
    var voiceOutputEnabled: Bool
    var voiceInputEnabled: Bool
    var agentAPIMode: AgentAPIMode
    var showTokenUsage: Bool
    var useWebSocket: Bool
    var webSocketPath: String
    var hapticsEnabled: Bool
    var appearance: Appearance

    static let defaults = AppSettings(
        gatewayURL: "",
        ttsProvider: .openai,
        sttProvider: .local,
        elevenLabsVoiceID: "21m00Tcm4TlvDq8ikWAM",
        openAIVoice: "alloy",
        fusionBackendURL: "http://127.0.0.1:18890",
        openclawVoice: "BV700_streaming",
        minimaxGroupID: "",
        minimaxAPIKey: "",
        minimaxDomain: "https://api.minimaxi.com",
        minimaxVoiceID: "female-shaonv",
        wechatBridgeURL: "",
        whisperModelSize: .small,
        whisperLanguage: "zh",
        voiceOutputEnabled: true,
        voiceInputEnabled: true,
        agentAPIMode: .openResponses,
        showTokenUsage: false,
        useWebSocket: false,
        webSocketPath: "/ws",
        hapticsEnabled: true,
        appearance: .dark
    )

    /// Build the full WebSocket URL from the gateway URL + port/path override.
    /// Examples:
    ///   gateway=https://example.com, wsPortOrPath=/ws       →  wss://example.com/ws
    ///   gateway=https://example.com, wsPortOrPath=ws        →  wss://example.com/ws
    ///   gateway=http://192.168.1.5,  wsPortOrPath=18789     →  ws://192.168.1.5:18789
    ///   gateway=http://192.168.1.5,  wsPortOrPath=:18789    →  ws://192.168.1.5:18789
    var resolvedWebSocketURL: String {
        let base = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base) else { return "" }

        let sourceScheme = components.scheme?.lowercased() ?? "https"
        components.scheme = (sourceScheme == "http") ? "ws" : "wss"

        let input = webSocketPath.trimmingCharacters(in: .whitespaces)

        // Strip optional leading colon for port input
        let normalized = input.hasPrefix(":") ? String(input.dropFirst()) : input

        if normalized.isEmpty {
            // Empty — use default port 18789
            components.port = 18789
            components.path = ""
        } else if let port = Int(normalized) {
            // Pure number → port (e.g. "18789" or ":18789")
            components.port = port
            components.path = ""
        } else {
            // String → path (e.g. "/ws", "ws")
            components.port = nil
            components.path = normalized.hasPrefix("/") ? normalized : "/\(normalized)"
        }

        return components.url?.absoluteString ?? ""
    }

    init(
        gatewayURL: String,
        ttsProvider: TTSProvider,
        sttProvider: STTProvider = .local,
        elevenLabsVoiceID: String,
        openAIVoice: String,
        fusionBackendURL: String = "http://127.0.0.1:18890",
        openclawVoice: String = "BV700_streaming",
        minimaxGroupID: String = "",
        minimaxAPIKey: String = "",
        minimaxDomain: String = "https://api.minimaxi.com",
        minimaxVoiceID: String = "female-shaonv",
        wechatBridgeURL: String = "",
        whisperModelSize: WhisperModelSize,
        whisperLanguage: String = "zh",
        voiceOutputEnabled: Bool,
        voiceInputEnabled: Bool,
        agentAPIMode: AgentAPIMode = .openResponses,
        showTokenUsage: Bool = false,
        useWebSocket: Bool = false,
        webSocketPath: String = "/ws",
        hapticsEnabled: Bool = true,
        appearance: Appearance = .dark
    ) {
        self.gatewayURL = gatewayURL
        self.ttsProvider = ttsProvider
        self.sttProvider = sttProvider
        self.elevenLabsVoiceID = elevenLabsVoiceID
        self.openAIVoice = openAIVoice
        self.fusionBackendURL = fusionBackendURL
        self.openclawVoice = openclawVoice
        self.minimaxGroupID = minimaxGroupID
        self.minimaxAPIKey = minimaxAPIKey
        self.minimaxDomain = minimaxDomain
        self.minimaxVoiceID = minimaxVoiceID
        self.wechatBridgeURL = wechatBridgeURL
        self.whisperModelSize = whisperModelSize
        self.whisperLanguage = whisperLanguage
        self.voiceOutputEnabled = voiceOutputEnabled
        self.voiceInputEnabled = voiceInputEnabled
        self.agentAPIMode = agentAPIMode
        self.showTokenUsage = showTokenUsage
        self.useWebSocket = useWebSocket
        self.webSocketPath = webSocketPath
        self.hapticsEnabled = hapticsEnabled
        self.appearance = appearance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gatewayURL = try container.decode(String.self, forKey: .gatewayURL)
        ttsProvider = try container.decode(TTSProvider.self, forKey: .ttsProvider)
        sttProvider = try container.decodeIfPresent(STTProvider.self, forKey: .sttProvider) ?? .local
        elevenLabsVoiceID = try container.decode(String.self, forKey: .elevenLabsVoiceID)
        openAIVoice = try container.decode(String.self, forKey: .openAIVoice)
        fusionBackendURL = try container.decodeIfPresent(String.self, forKey: .fusionBackendURL) ?? "http://127.0.0.1:18890"
        openclawVoice = try container.decodeIfPresent(String.self, forKey: .openclawVoice) ?? "BV700_streaming"
        minimaxGroupID = try container.decodeIfPresent(String.self, forKey: .minimaxGroupID) ?? ""
        minimaxAPIKey = try container.decodeIfPresent(String.self, forKey: .minimaxAPIKey) ?? ""
        minimaxDomain = try container.decodeIfPresent(String.self, forKey: .minimaxDomain) ?? "https://api.minimaxi.com"
        minimaxVoiceID = try container.decodeIfPresent(String.self, forKey: .minimaxVoiceID) ?? "female-shaonv"
        wechatBridgeURL = try container.decodeIfPresent(String.self, forKey: .wechatBridgeURL) ?? ""
        whisperModelSize = try container.decode(WhisperModelSize.self, forKey: .whisperModelSize)
        whisperLanguage = try container.decodeIfPresent(String.self, forKey: .whisperLanguage) ?? "zh"
        voiceOutputEnabled = try container.decode(Bool.self, forKey: .voiceOutputEnabled)
        voiceInputEnabled = try container.decode(Bool.self, forKey: .voiceInputEnabled)
        agentAPIMode = try container.decodeIfPresent(AgentAPIMode.self, forKey: .agentAPIMode) ?? .openResponses
        showTokenUsage = try container.decodeIfPresent(Bool.self, forKey: .showTokenUsage) ?? false
        useWebSocket = try container.decodeIfPresent(Bool.self, forKey: .useWebSocket) ?? false
        hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .dark

        // Migrate legacy webSocketPort → webSocketPath
        if let legacyPort = try container.decodeIfPresent(Int.self, forKey: .webSocketPort) {
            webSocketPath = ":\(legacyPort)"
        } else {
            webSocketPath = try container.decodeIfPresent(String.self, forKey: .webSocketPath) ?? "/ws"
        }
    }

    enum CodingKeys: String, CodingKey {
        case gatewayURL, ttsProvider, sttProvider, elevenLabsVoiceID, openAIVoice, fusionBackendURL, openclawVoice
        case minimaxGroupID, minimaxAPIKey, minimaxDomain, minimaxVoiceID, wechatBridgeURL
        case whisperModelSize, whisperLanguage, voiceOutputEnabled, voiceInputEnabled
        case agentAPIMode, showTokenUsage, useWebSocket
        case webSocketPath, webSocketPort // webSocketPort for legacy decode only
        case hapticsEnabled
        case appearance
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gatewayURL, forKey: .gatewayURL)
        try container.encode(ttsProvider, forKey: .ttsProvider)
        try container.encode(sttProvider, forKey: .sttProvider)
        try container.encode(elevenLabsVoiceID, forKey: .elevenLabsVoiceID)
        try container.encode(openAIVoice, forKey: .openAIVoice)
        try container.encode(fusionBackendURL, forKey: .fusionBackendURL)
        try container.encode(openclawVoice, forKey: .openclawVoice)
        try container.encode(minimaxGroupID, forKey: .minimaxGroupID)
        try container.encode(minimaxAPIKey, forKey: .minimaxAPIKey)
        try container.encode(minimaxDomain, forKey: .minimaxDomain)
        try container.encode(minimaxVoiceID, forKey: .minimaxVoiceID)
        try container.encode(wechatBridgeURL, forKey: .wechatBridgeURL)
        try container.encode(whisperModelSize, forKey: .whisperModelSize)
        try container.encode(whisperLanguage, forKey: .whisperLanguage)
        try container.encode(voiceOutputEnabled, forKey: .voiceOutputEnabled)
        try container.encode(voiceInputEnabled, forKey: .voiceInputEnabled)
        try container.encode(agentAPIMode, forKey: .agentAPIMode)
        try container.encode(showTokenUsage, forKey: .showTokenUsage)
        try container.encode(useWebSocket, forKey: .useWebSocket)
        try container.encode(webSocketPath, forKey: .webSocketPath)
        try container.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try container.encode(appearance, forKey: .appearance)
        // webSocketPort intentionally not encoded — legacy only
    }
}
