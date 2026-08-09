import Foundation
import AVFoundation

/// MiniMax TTS 直连客户端（官方 t2a_v2 接口）。
///
/// 音频格式说明（官方文档 platform.minimax.io/docs/api-reference/speech-t2a-http）：
/// - 流式模式（stream=true）下 audio_setting.format 仅支持 mp3；
/// - 流式输出只支持 output_format="hex"，SSE 行格式为
///   `data: {"data":"<hex 编码的 mp3 字节>"}`；
/// - 因此客户端需要把各条 SSE 的 hex 拼接成完整 mp3，再用 AVAudioFile
///   解码为 24kHz 单声道 Float32 PCM 后分块交给 AudioPlaybackManager 播放。
final class MiniMaxTTSService: SpeechService {
    private let groupID: String
    private let apiKey: String
    private let domain: String
    private let voiceID: String
    private let session: URLSession
    private var currentTask: Task<Void, Never>?

    init(
        groupID: String,
        apiKey: String,
        domain: String = "https://api.minimaxi.com",
        voiceID: String = "female-shaonv"
    ) {
        self.groupID = groupID
        self.apiKey = apiKey
        self.domain = domain
        self.voiceID = voiceID
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func streamSpeech(text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(text: text)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw MiniMaxTTSError.httpError(status)
                    }

                    // 逐行读取 SSE，把 hex 编码的 mp3 字节拼接起来。
                    var mp3Hex = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let chunk = Self.extractHex(from: payload), !chunk.isEmpty {
                            mp3Hex += chunk
                        }
                    }

                    guard !mp3Hex.isEmpty, let mp3Data = Self.hexToData(mp3Hex), !mp3Data.isEmpty else {
                        throw MiniMaxTTSError.decodeFailed
                    }

                    // mp3 需要完整数据才能解码，先整段解码为 Float32 PCM 再分块下发。
                    let pcm = try Self.decodeMP3ToFloat32PCM(mp3Data)
                    let chunks = Self.chunkedFloat32PCM(pcm)
                    if chunks.isEmpty {
                        continuation.finish()
                    } else {
                        for chunk in chunks {
                            if Task.isCancelled { break }
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            currentTask = task
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Request

    private func buildRequest(text: String) throws -> URLRequest {
        let trimmedDomain = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedDomain.isEmpty, !trimmedGroupID.isEmpty, !trimmedKey.isEmpty,
              var components = URLComponents(string: "\(trimmedDomain)/v1/t2a_v2") else {
            throw MiniMaxTTSError.invalidConfiguration
        }
        components.queryItems = [URLQueryItem(name: "GroupId", value: trimmedGroupID)]
        guard let url = components.url else {
            throw MiniMaxTTSError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "speech-02-hd",
            "text": text,
            "stream": true,
            "output_format": "hex",
            "voice_setting": [
                "voice_id": voiceID,
                "speed": 1.0,
                "vol": 1.0,
                "pitch": 0
            ],
            // 流式模式只支持 mp3；hex 输出保证 SSE 里是纯 hex 字符串。
            "audio_setting": [
                "sample_rate": 24000,
                "format": "mp3",
                "channel": 1
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Hex / PCM Conversion

    /// 从 SSE payload 中提取 hex 字符串。
    /// 兼容两种形式：
    ///   {"data":"<hex>"}      —— JSON 包裹
    ///   <hex>                 —— 裸 hex
    private static func extractHex(from payload: String) -> String? {
        if payload.hasPrefix("{") {
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = json["data"] as? String else {
                return nil
            }
            return value
        }
        return payload
    }

    /// hex 字符串 → Data。
    private static func hexToData(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// 把 Float32 PCM 切成小块（2400 采样 ≈ 100ms @ 24kHz），便于播放器缓冲。
    private static func chunkedFloat32PCM(_ data: Data) -> [Data] {
        let chunkBytes = 2400 * MemoryLayout<Float>.size
        guard !data.isEmpty else { return [] }
        var chunks: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkBytes, data.count)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }

    // MARK: - MP3 Decode

    /// 用 AVAudioFile 把整段 mp3 解码为 24kHz 单声道 Float32 PCM。
    private static func decodeMP3ToFloat32PCM(_ mp3Data: Data) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try mp3Data.write(to: tempURL)

        let audioFile = try AVAudioFile(forReading: tempURL)
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            throw MiniMaxTTSError.decodeFailed
        }
        try audioFile.read(into: buffer)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw MiniMaxTTSError.decodeFailed
        }
        let frameCount = Int(buffer.frameLength)
        return Data(bytes: channelData, count: frameCount * MemoryLayout<Float>.size)
    }
}

/// MiniMax 专用错误，文案为中文，遵循现有 TTSError 的 LocalizedError 模式。
enum MiniMaxTTSError: LocalizedError {
    case httpError(Int)
    case invalidConfiguration
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "MiniMax 语音服务返回错误（HTTP \(code)）。请检查 Group ID、API Key 与网络连接。"
        case .invalidConfiguration:
            return "MiniMax 语音未配置完整，请在设置中填写 Group ID 与 API Key。"
        case .decodeFailed:
            return "MiniMax 音频解码失败，请更换音色或稍后重试。"
        }
    }
}
