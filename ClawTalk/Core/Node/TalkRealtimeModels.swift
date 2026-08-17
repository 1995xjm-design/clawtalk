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

struct TalkGatewaySpeechRequest: Encodable {
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