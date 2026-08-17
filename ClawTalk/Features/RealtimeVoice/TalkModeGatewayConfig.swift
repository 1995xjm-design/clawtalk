import Foundation

/// Talk 执行模式（对齐官方 TalkModeExecutionMode）。
enum TalkModeExecutionMode: Equatable {
    case native
    case realtimeWebRTC
    case realtimeRelay
}

/// 运行期问题（对齐官方 TalkRuntimeIssue）：Realtime 启动失败时给降级提示。
struct TalkRuntimeIssue: Equatable {
    enum Code: String {
        case realtimeUnavailable = "realtime_unavailable"
    }

    let code: Code
    let message: String
    let provider: String?
    let model: String?
    let transport: String?
    let phase: String?

    init(code: Code, message: String, provider: String? = nil, model: String? = nil,
         transport: String? = nil, phase: String? = nil) {
        self.code = code
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phase = phase?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayMessage: String {
        !message.isEmpty ? message : "实时语音未启动。"
    }

    var fallbackStatusText: String { "收听中（iOS 语音降级）" }
    var fallbackBannerTitle: String { "使用 iOS 语音降级" }
    var fallbackBannerOwnerLabel: String { "降级生效" }
    var fallbackBannerMessage: String { "实时语音未启动，正在使用 iOS 本地语音识别与合成。" }

    var technicalDetails: String { diagnosticSummary }

    var diagnosticSummary: String {
        var parts = [displayMessage]
        if let provider, !provider.isEmpty { parts.append("provider: \(provider)") }
        if let model, !model.isEmpty { parts.append("model: \(model)") }
        if let transport, !transport.isEmpty { parts.append("transport: \(transport)") }
        if let phase, !phase.isEmpty { parts.append("phase: \(phase)") }
        return parts.joined(separator: " · ")
    }

    static func realtimeUnavailable(message: String, provider: String? = nil,
                                    model: String? = nil, transport: String? = nil,
                                    phase: String? = nil) -> TalkRuntimeIssue {
        TalkRuntimeIssue(code: .realtimeUnavailable, message: message,
                         provider: provider, model: model, transport: transport, phase: phase)
    }
}

/// 语音模式描述（对齐官方 TalkVoiceModeDescriptor）。
struct TalkVoiceModeDescriptor: Equatable {
    let title: String
    let subtitle: String?
    let providerId: String?
    let modelId: String?
    let voiceId: String?
    let transport: String?
    let isRealtime: Bool
}

enum TalkVoiceModeDescriptorBuilder {
    static func build(providerId: String, providerLabel: String, modelId: String?,
                      voiceId: String?, transport: String?, isRealtime: Bool) -> TalkVoiceModeDescriptor {
        let normalizedProvider = providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title: String
        if isRealtime, normalizedProvider == "openai", modelId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gpt-realtime-2" {
            title = "GPT Realtime 2.0"
        } else if isRealtime, normalizedProvider == "openai" {
            title = "OpenAI Realtime"
        } else if isRealtime {
            title = providerLabel.isEmpty ? "Realtime 语音" : providerLabel
        } else {
            title = providerLabel.isEmpty ? "语音模式" : providerLabel
        }
        var subtitleParts: [String] = []
        if let modelId = Self.trimmed(modelId) { subtitleParts.append(modelId) }
        if let voiceId = Self.trimmed(voiceId) { subtitleParts.append(voiceId) }
        if let transport = Self.trimmed(transport) { subtitleParts.append(transport) }
        return TalkVoiceModeDescriptor(
            title: title,
            subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
            providerId: providerId,
            modelId: modelId,
            voiceId: voiceId,
            transport: transport,
            isRealtime: isRealtime)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Provider 选择（对齐官方 TalkModeProviderSelection）。
enum TalkModeProviderSelection: String, CaseIterable, Identifiable {
    case auto
    case openai
    case gateway

    var id: String { rawValue }

    static func resolved(_ raw: String?) -> TalkModeProviderSelection {
        guard let raw else { return .auto }
        return TalkModeProviderSelection(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .auto
    }

    var usesRealtime: Bool { self == .openai }
    var usesGatewayTalkSpeak: Bool { self == .gateway || self == .auto }
    var gatewayOwnsCredentials: Bool { self != .openai }
}

/// 运行时路由（对齐官方 TalkModeRuntimeRoute 精简）。
enum TalkModeRuntimeRoute: Equatable {
    case native
    case realtime(provider: String, model: String?, voice: String?, transport: String)
    case relay(provider: String)
}

struct TalkModeResolvedRouting: Equatable {
    let executionMode: TalkModeExecutionMode
    let provider: String?
    let model: String?
    let voice: String?
    let transport: String?
}

/// 路由解析（对齐官方 TalkModeRoutingResolver）：按能力探测结果选执行模式。
enum TalkModeRoutingResolver {
    static func resolve(
        supportsRealtime: Bool,
        providerSelection: TalkModeProviderSelection = .auto,
        provider: String = "openai",
        model: String? = nil,
        voice: String? = nil,
        transport: String = "webrtc") -> TalkModeResolvedRouting
    {
        if supportsRealtime && providerSelection.usesRealtime {
            return TalkModeResolvedRouting(
                executionMode: .realtimeWebRTC,
                provider: provider, model: model, voice: voice, transport: transport)
        }
        return TalkModeResolvedRouting(
            executionMode: .native,
            provider: nil, model: nil, voice: nil, transport: nil)
    }
}

/// 网关语音配置状态（对齐官方 TalkModeGatewayConfigState）：本地持久化 provider/model/voice/transport。
struct TalkModeGatewayConfigState {
    static let storageKey = "talk.mode.gateway.config"

    struct Snapshot: Codable, Equatable {
        var provider: String?
        var model: String?
        var voice: String?
        var transport: String?
    }

    static func load(defaults: UserDefaults = .standard) -> Snapshot {
        guard let data = defaults.data(forKey: storageKey) else { return Snapshot() }
        return (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? Snapshot()
    }

    static func save(_ snapshot: Snapshot, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
