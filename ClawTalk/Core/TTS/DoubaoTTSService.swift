import Foundation

/// 豆包（火山引擎）语音合成客户端直连（Doubao TTS）。
///
/// 协议：openspeech v3 单向流式 WebSocket
///   wss://openspeech.bytedance.com/api/v3/tts/unidirectional/stream
/// 鉴权：X-Api-Key（语音控制台 API Key）+ X-Api-Resource-Id: seed-tts-2.0
/// 输出：pcm（s16le 24kHz mono）→ 转 Float32 逐块输出，可边收边播、可打断。
final class DoubaoTTSService: SpeechService {
    private let apiKey: String
    private let voiceID: String
    private let resourceID: String
    private let sampleRate: Int

    private var webSocketTask: URLSessionWebSocketTask?
    private var isStopped = false
    private let lock = NSLock()

    init(apiKey: String, voiceID: String, resourceID: String = "seed-tts-2.0", sampleRate: Int = 24000) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.resourceID = resourceID
        self.sampleRate = sampleRate
    }

    func streamSpeech(text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let url = URL(string: "wss://openspeech.bytedance.com/api/v3/tts/unidirectional/stream")!
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: request)
            self.lock.lock()
            self.webSocketTask = task
            self.isStopped = false
            self.lock.unlock()

            // 请求帧：[0x11,0x10,0x10,0x00] + uint32 BE payload length + JSON
            let payload: [String: Any] = [
                "user": ["uid": "clawtalk-ios"],
                "req_params": [
                    "text": text,
                    "speaker": voiceID,
                    "audio_params": ["format": "pcm", "sample_rate": sampleRate]
                ]
            ]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                continuation.finish(throwing: DoubaoTTSError.invalidPayload)
                return
            }
            var frame = Data([0x11, 0x10, 0x10, 0x00])
            var payloadLen = UInt32(jsonData.count).bigEndian
            frame.append(Data(bytes: &payloadLen, count: 4))
            frame.append(jsonData)

            task.resume()
            task.send(.data(frame)) { error in
                if let error {
                    continuation.finish(throwing: error)
                }
            }

            func receive() {
                task.receive { [weak self] result in
                    guard let self else { return }
                    if self.isStopped {
                        continuation.finish()
                        return
                    }
                    switch result {
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    case .success(let message):
                        switch message {
                        case .data(let data):
                            self.handleFrame(data, continuation: continuation, next: receive)
                        case .string(let string):
                            continuation.finish(throwing: DoubaoTTSError.serverMessage(string))
                        @unknown default:
                            continuation.finish()
                        }
                    }
                }
            }
            receive()

            continuation.onTermination = { [weak self] _ in
                // 只取消「自己的」连接，避免误杀下一次朗读新建的 WebSocket
                guard let self else { return }
                self.lock.lock()
                let isCurrent = self.webSocketTask === task
                self.lock.unlock()
                if isCurrent {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        lock.lock()
        isStopped = true
        lock.unlock()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - 帧解析

    private func handleFrame(
        _ data: Data,
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        next: @escaping () -> Void
    ) {
        guard data.count >= 4 else {
            continuation.finish(throwing: DoubaoTTSError.malformedFrame)
            return
        }
        let msgType = (data[1] >> 4) & 0x0F
        var offset = 4

        // 错误帧：uint32 code + uint32 len + payload
        if msgType == 0b1111 {
            guard data.count >= offset + 8 else {
                continuation.finish(throwing: DoubaoTTSError.malformedFrame)
                return
            }
            let code = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            offset += 4
            let bodyLen = Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            offset += 4
            guard data.count >= offset + bodyLen else {
                continuation.finish(throwing: DoubaoTTSError.malformedFrame)
                return
            }
            let body = String(data: data.subdata(in: offset..<offset + bodyLen), encoding: .utf8) ?? ""
            continuation.finish(throwing: DoubaoTTSError.serverError(code, body))
            return
        }

        // event 号
        guard data.count >= offset + 4 else {
            continuation.finish(throwing: DoubaoTTSError.malformedFrame)
            return
        }
        let event = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        offset += 4

        // session id：uint32 len + bytes
        guard data.count >= offset + 4 else {
            continuation.finish(throwing: DoubaoTTSError.malformedFrame)
            return
        }
        let sidLen = Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        offset += 4
        guard data.count >= offset + sidLen + 4 else {
            continuation.finish(throwing: DoubaoTTSError.malformedFrame)
            return
        }
        offset += sidLen

        // payload
        guard data.count >= offset + 4 else {
            continuation.finish(throwing: DoubaoTTSError.malformedFrame)
            return
        }
        let payloadLen = Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        offset += 4
        guard data.count >= offset + payloadLen else {
            continuation.finish(throwing: DoubaoTTSError.malformedFrame)
            return
        }
        let payload = data.subdata(in: offset..<offset + payloadLen)

        if msgType == 0b1011, !payload.isEmpty {
            let floats = DoubaoTTSService.pcm16ToFloats(payload)
            if !floats.isEmpty {
                let chunk = floats.withUnsafeBytes { Data($0) }
                continuation.yield(chunk)
            }
        }

        // 152=SessionFinished 52=ConnectionFinished → 结束
        if event == 152 || event == 52 {
            continuation.finish()
            return
        }
        next()
    }

    /// s16le PCM → Float32（-1...1）
    static func pcm16ToFloats(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                out[i] = Float(samples[i]) / 32768.0
            }
        }
        return out
    }
}

enum DoubaoTTSError: LocalizedError {
    case invalidPayload
    case serverMessage(String)
    case serverError(UInt32, String)
    case malformedFrame

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "豆包 TTS 请求构造失败"
        case .serverMessage(let message):
            return "豆包 TTS 服务端返回：\(message)"
        case .serverError(let code, let message):
            return "豆包 TTS 错误(\(code))：\(message)"
        case .malformedFrame:
            return "豆包 TTS 响应格式异常"
        }
    }
}
