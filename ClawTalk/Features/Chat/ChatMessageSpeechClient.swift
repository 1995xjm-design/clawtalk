import AVFoundation
import Foundation

/// 聊天消息朗读（对齐官方 ChatMessageSpeechClient / tts.speak）：
/// 通过网关 TTS 合成并播放，降级 AVSpeechSynthesizer 本地朗读。
enum ChatMessageSpeechClient {
    typealias Request = (_ method: String, _ paramsJSON: String?, _ timeoutSeconds: Int) async throws -> Data
    private static let requestTimeoutSeconds = 60

    static func synthesize(text: String, gatewayConnection: GatewayConnection) async throws -> Data {
        try await synthesize(text: text) { method, paramsJSON, timeoutSeconds in
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

    static func synthesize(text: String, request: Request) async throws -> Data {
        let params = TtsSpeakParams(text: text)
        let paramsData = try JSONEncoder().encode(params)
        guard let paramsJSON = String(data: paramsData, encoding: .utf8) else {
            throw ChatMessageSpeechError.invalidRequest
        }
        let responseData = try await request("tts.speak", paramsJSON, Self.requestTimeoutSeconds)
        let response: TtsSpeakResult
        do {
            response = try JSONDecoder().decode(TtsSpeakResult.self, from: responseData)
        } catch {
            throw ChatMessageSpeechError.invalidRequest
        }
        guard let audioData = Data(base64Encoded: response.audiobase64 ?? ""), !audioData.isEmpty else {
            throw ChatMessageSpeechError.emptyAudio
        }
        return audioData
    }

    /// 播放 TTS 音频；返回是否播放成功。
    @discardableResult
    static func play(_ audioData: Data) async -> Bool {
        guard let player = try? AVAudioPlayer(data: audioData) else { return false }
        player.play()
        return true
    }

    /// 本地降级朗读（AVSpeechSynthesizer）。
    static func speakLocally(_ text: String) {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        synthesizer.speak(utterance)
    }
}

private struct TtsSpeakParams: Encodable {
    var text: String
}

private struct TtsSpeakResult: Codable {
    var audiobase64: String?
    var outputformat: String?
    var mimetype: String?
    var fileextension: String?
}

enum ChatMessageSpeechError: LocalizedError {
    case invalidRequest
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "无法编码 tts.speak 请求"
        case .emptyAudio: return "网关 tts.speak 返回空音频"
        }
    }
}
