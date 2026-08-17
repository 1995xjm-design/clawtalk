import AVFoundation
import Foundation

/// 网关语音合成（对齐官方 TalkGatewaySpeechClient / talk.speak）：
/// 通过网关 RPC 生成语音并播放（PCM 采样率直放 / 缓冲文件播放）。
struct TalkGatewaySpeechAudio: Equatable {
    enum PlaybackMode: Equatable {
        case pcm(sampleRate: Double)
        case buffered
        case unsupportedRaw(codec: String)
    }

    let data: Data
    let provider: String
    let outputFormat: String?

    var playbackMode: PlaybackMode {
        if let sampleRate = Self.pcmSampleRate(from: outputFormat) {
            return .pcm(sampleRate: sampleRate)
        }
        let format = outputFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let format, format.hasPrefix("raw-") || format.hasPrefix("raw_") || format == "pcm"
            || format == "mulaw" || format == "alaw" {
            return .unsupportedRaw(codec: format)
        }
        return .buffered
    }

    static func pcmSampleRate(from format: String?) -> Double? {
        guard let format else { return nil }
        let lower = format.lowercased()
        guard lower.hasPrefix("pcm") || lower.hasPrefix("pcm-") || lower.hasPrefix("pcm_") else { return nil }
        let digits = lower.filter { $0.isNumber }
        guard let rate = Double(digits), rate > 0 else { return nil }
        return rate
    }
}

struct TalkGatewaySpeechRequest: Encodable {
    var text: String
    var voiceId: String?
    var modelId: String?
    var outputFormat: String?
    var speed: Double?
    var rateWPM: Double?
    var language: String?

    private enum CodingKeys: String, CodingKey {
        case text, speed, language
        case voiceId = "voiceid"
        case modelId = "modelid"
        case outputFormat = "outputformat"
        case rateWPM = "ratewpm"
    }
}

struct TalkSpeakResult: Codable {
    var audiobase64: String?
    var provider: String?
    var outputformat: String?
    var error: String?
}

enum TalkGatewaySpeechError: LocalizedError {
    case invalidRequest
    case emptyAudio
    case gatewayRejected(String?)
    case playback(Error?)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "语音合成请求无效"
        case .emptyAudio: return "网关返回空音频"
        case .gatewayRejected(let message): return message ?? "网关拒绝语音合成"
        case .playback: return "语音播放失败"
        }
    }
}

@MainActor
final class TalkGatewaySpeechClient {
    typealias Request = (_ method: String, _ paramsJSON: String?, _ timeoutSeconds: Int) async throws -> Data
    private static let requestTimeoutSeconds = 125

    private let request: Request
    private var audioPlayer: AVAudioPlayer?

    init(request: @escaping Request) {
        self.request = request
    }

    convenience init(gatewayConnection: GatewayConnection) {
        self.init { method, paramsJSON, timeoutSeconds in
            var params: [String: AnyCodable]?
            if let paramsJSON, let data = paramsJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                params = object.mapValues { AnyCodable($0) }
            }
            return try await gatewayConnection.request(
                method: method,
                params: params,
                timeoutMs: Double(timeoutSeconds) * 1000)
        }
    }

    func synthesize(_ speechRequest: TalkGatewaySpeechRequest) async throws -> TalkGatewaySpeechAudio {
        let paramsData = try JSONEncoder().encode(speechRequest)
        guard let paramsJSON = String(data: paramsData, encoding: .utf8) else {
            throw TalkGatewaySpeechError.invalidRequest
        }
        let responseData = try await request("talk.speak", paramsJSON, Self.requestTimeoutSeconds)
        let response: TalkSpeakResult
        do {
            response = try JSONDecoder().decode(TalkSpeakResult.self, from: responseData)
        } catch {
            if let text = String(data: responseData, encoding: .utf8), !text.isEmpty,
               let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let error = object["error"] as? String {
                throw TalkGatewaySpeechError.gatewayRejected(error)
            }
            throw TalkGatewaySpeechError.invalidRequest
        }
        if let error = response.error, !error.isEmpty {
            throw TalkGatewaySpeechError.gatewayRejected(error)
        }
        guard let audioData = Data(base64Encoded: response.audiobase64 ?? ""), !audioData.isEmpty else {
            throw TalkGatewaySpeechError.emptyAudio
        }
        return TalkGatewaySpeechAudio(
            data: audioData,
            provider: response.provider ?? "gateway",
            outputFormat: response.outputformat)
    }

    /// 播放合成音频（PCM 或 buffered）。返回播放时长（秒）。
    @discardableResult
    func play(_ audio: TalkGatewaySpeechAudio) async -> Double? {
        switch audio.playbackMode {
        case .pcm(let sampleRate):
            return Self.playPCM(audio.data, sampleRate: sampleRate)
        case .buffered:
            do {
                audioPlayer = try AVAudioPlayer(data: audio.data)
                audioPlayer?.play()
                return audioPlayer?.duration
            } catch {
                return nil
            }
        case .unsupportedRaw:
            return nil
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private static func playPCM(_ data: Data, sampleRate: Double) -> Double? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true)
        guard let format,
              let player = try? AVAudioPlayerNodePlayer(format: format, data: data) else { return nil }
        player.play()
        return player.duration
    }
}

/// 轻量 PCM 播放器包装（AVAudioPlayerNode 支持原生 PCM 数据）。
private final class AVAudioPlayerNodePlayer {
    let duration: Double
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode

    init?(format: AVAudioFormat, data: Data) {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count) / 2)
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { raw in
            buffer.int16ChannelData?.pointee.update(from: raw.bindMemory(to: Int16.self).baseAddress!,
                                                    count: Int(buffer.frameLength))
        }
        player.scheduleBuffer(buffer)
        do {
            try engine.start()
        } catch {
            return nil
        }
        duration = Double(buffer.frameLength) / format.sampleRate
    }

    func play() {
        player.play()
    }
}
