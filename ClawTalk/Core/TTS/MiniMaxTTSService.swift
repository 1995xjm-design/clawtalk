import Foundation
import AVFoundation

/// MiniMax TTS 直连客户端（官方 t2a_v2 流式接口）。
///
/// 音频格式说明（实现选择）：
/// - 主路径：请求体携带 audio_setting.format = "pcm"、sample_rate = 24000，
///   服务端流式返回 16-bit 有符号小端、24kHz 单声道的裸 PCM 字节，
///   App 侧只需做 Int16 → Float32 转换即可交给 AudioPlaybackManager 播放，无需解码。
/// - 退路：若服务端忽略 pcm 请求、实际返回了 mp3（按响应文件头魔数探测），
///   则整段收集后用 AVAudioFile 解码为 24kHz 单声道 Float32 PCM 再按块下发。
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

                    // MiniMax t2a_v2 流式接口返回 SSE 格式：
                    //   data: {"data":"<base64 PCM>","extra_info":{...},...}
                    //   data: [DONE]
                    // 逐行读取，从每行 JSON 中提取 base64 音频数据。
                    var collectedPCM = Data()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let payloadData = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                              let audioB64 = json["data"] as? String,
                              let audioRaw = Data(base64Encoded: audioB64) else {
                            continue
                        }
                        // 每帧是 16-bit LE PCM（24kHz 单声道），累积后分块下发
                        collectedPCM.append(audioRaw)
                        // 每 4800 字节（100ms）输出一块
                        while collectedPCM.count >= 4800 {
                            let chunk = collectedPCM.prefix(4800)
                            collectedPCM.removeFirst(4800)
                            continuation.yield(Self.int16ToFloat32(Data(chunk)))
                        }
                    }
                    // 输出剩余不足 100ms 的尾块
                    if !collectedPCM.isEmpty {
                        continuation.yield(Self.int16ToFloat32(collectedPCM))
                    }

                    continuation.finish()
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
            "voice_setting": [
                "voice_id": voiceID,
                "speed": 1.0,
                "vol": 1.0,
                "pitch": 0
            ],
            // 官方 t2a_v2 的音频格式参数位于 audio_setting.format（pcm/mp3），
            // 这里请求 pcm 以省去 mp3 解码；若服务端不支持会退化为 mp3 分支。
            "audio_setting": [
                "sample_rate": 24000,
                "format": "pcm"
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - PCM Conversion

    /// 16-bit 有符号小端 PCM → Float32 PCM（与 ElevenLabs/OpenAI 服务保持一致）。
    private static func int16ToFloat32(_ data: Data) -> Data {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return Data() }
        var float32Data = Data(count: sampleCount * MemoryLayout<Float>.size)
        data.withUnsafeBytes { raw in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            float32Data.withUnsafeMutableBytes { out in
                let floatPtr = out.bindMemory(to: Float.self)
                for i in 0..<sampleCount {
                    floatPtr[i] = Float(int16Ptr[i]) / Float(Int16.max)
                }
            }
        }
        return float32Data
    }

    /// 把 Float32 PCM 切成小块（2400 采样 ≈ 100ms @ 24kHz），便于边播边收。
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

    // MARK: - MP3 Fallback

    /// 探测音频文件头：mp3 以 "ID3" 标签或 0xFFEx MPEG 帧同步开头。
    private static func dataLooksLikeMP3(_ head: Data) -> Bool {
        if head.count >= 3, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 {
            return true // "ID3"
        }
        if head.count >= 2, head[0] == 0xFF, (head[1] & 0xE0) == 0xE0 {
            return true // MPEG audio frame sync
        }
        return false
    }

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