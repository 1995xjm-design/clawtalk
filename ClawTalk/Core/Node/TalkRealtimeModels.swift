import Foundation

/// 官方 Talk 实时语音协议模型（对齐 TalkRealtimeClientSession / TalkRealtimeWebRTCSession / TalkGatewaySpeechClient）。

// MARK: - talk.client RPC

struct TalkRealtimeClientCreateParams: Encodable {
    var sessionKey: String?
    var voiceSessionId: String?
    var mode = "realtime"
    var provider: String?
    var transport = "webrtc"
    var brain = "agent-consult"
    var model: String?
    var voice: String?
    var capabilities: [String]

    init(
        sessionKey: String? = nil,
        voiceSessionId: String? = nil,
        provider: String? = nil,
        transport: String = "webrtc",
        model: String? = nil,
        voice: String? = nil,
        capabilities: [String] = ["audio", "transcripts"]
    ) {
        self.sessionKey = sessionKey
        self.voiceSessionId = voiceSessionId
        self.provider = provider
        self.transport = transport
        self.model = model
        self.voice = voice
        self.capabilities = capabilities
    }
}

struct TalkRealtimeClientCloseParams: Encodable {
    var sessionKey: String?
    var voiceSessionId: String?
}

struct TalkRealtimeClientResponse: Codable {
    var ok: Bool?
    var sessionKey: String?
    var voiceSessionId: String?
    var transport: String?
    var error: String?
}

// MARK: - OpenAI Realtime 事件（官方 TalkRealtimeWebRTCSession 事件流）

enum TalkRealtimeEventType: String {
    case sessionCreated = "session.created"
    case sessionUpdated = "session.updated"
    case inputAudioBufferCommitted = "input_audio_buffer.committed"
    case inputAudioBufferSpeechStarted = "input_audio_buffer.speech_started"
    case inputAudioBufferSpeechStopped = "input_audio_buffer.speech_stopped"
    case inputAudioTranscriptionCompleted = "conversation.item.input_audio_transcription.completed"
    case inputAudioTranscriptionDelta = "conversation.item.input_audio_transcription.delta"
    case conversationItemCreated = "conversation.item.created"
    case conversationItemDone = "conversation.item.done"
    case conversationInputTranscriptDelta = "conversation.input_transcript.delta"
    case conversationInputTranscriptDone = "conversation.input_transcript.done"
    case conversationOutputTranscriptDelta = "conversation.output_transcript.delta"
    case conversationOutputTranscriptDone = "conversation.output_transcript.done"
    case conversationOutputAudioDelta = "conversation.output_audio.delta"
    case conversationOutputAudioDone = "conversation.output_audio.done"
    case responseCreated = "response.created"
    case responseDone = "response.done"
    case responseAudioDelta = "response.audio.delta"
    case responseAudioDone = "response.audio.done"
    case responseAudioTranscriptDelta = "response.audio_transcript.delta"
    case responseAudioTranscriptDone = "response.audio_transcript.done"
    case responseOutputItemAdded = "response.output_item.added"
    case responseOutputItemDone = "response.output_item.done"
    case responseFunctionCallArgumentsDelta = "response.function_call_arguments.delta"
    case responseFunctionCallArgumentsDone = "response.function_call_arguments.done"
    case error = "error"

    init?(raw: String) {
        self.init(rawValue: raw)
    }
}

/// 网关推送的 talk 事件帧（WS 事件透传 Realtime 事件 type）。
struct TalkRealtimeEvent: Codable {
    var type: String?
    var sessionKey: String?
    var transcript: String?
    var delta: String?
    var itemId: String?
    var error: String?

    var eventType: TalkRealtimeEventType? {
        type.flatMap(TalkRealtimeEventType.init(raw:))
    }
}

// MARK: - TalkGatewaySpeech（网关语音合成，对齐 TalkGatewaySpeechClient）

struct TalkGatewaySpeechParams: Encodable {
    var text: String
    var voice: String?
    var sessionKey: String?
    var stream: Bool?
}

struct TalkGatewaySpeechResponse: Codable {
    var audio: String?
    var format: String?
    var sampleRate: Double?
    var error: String?
}

// MARK: - TalkRealtime 服务端事件家族（对齐官方 TalkRealtimeClientSession 模型）

enum TalkRealtimeTranscriptRole: String, Encodable {
    case user
    case assistant
}

struct TalkRealtimeTranscriptParams: Encodable {
    let sessionKey: String
    let voiceSessionId: String
    let entryId: String
    let role: TalkRealtimeTranscriptRole
    let text: String
    let timestamp: Double?
}

struct TalkRealtimeToolCallResponse: Decodable {
    let runId: String?
    let idempotencyKey: String?
}

struct TalkRealtimeServerEvent: Decodable {
    let type: String
    let error: TalkRealtimeServerError?
    let itemId: String?
    let item: TalkRealtimeServerItem?
    let turn: TalkRealtimeServerTurn?
    let callId: String?
    let name: String?
    let delta: String?
    let arguments: String?
    let transcript: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case type
        case error
        case itemId = "item_id"
        case item
        case turn
        case callId = "call_id"
        case name
        case delta
        case arguments
        case transcript
        case text
    }

    var resolvedItemId: String? { itemId ?? item?.id }
    var resolvedCallId: String? { callId ?? item?.callId }
    var resolvedName: String? { name ?? item?.name }
    var resolvedArguments: String? { arguments ?? item?.arguments }

    var isMaximumDurationError: Bool {
        guard type == "error", let message = error?.message?.lowercased() else { return false }
        return message.contains("session") && message.contains("maximum duration")
    }
}

struct TalkRealtimeServerError: Decodable {
    let message: String?
}

struct TalkRealtimeServerTurn: Decodable {
    let id: String?
    let role: String?
    let transcript: String?
}

struct TalkRealtimeServerItem: Decodable {
    let id: String?
    let type: String?
    let text: String?
    let callId: String?
    let name: String?
    let arguments: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case text
        case callId = "call_id"
        case name
        case arguments
    }
}
