import Foundation

/// 豆包（火山引擎）流式语音识别客户端直连（Doubao ASR）。
///
/// 协议：openspeech v3 大模型 ASR（流式输入模式）
///   wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async
/// 鉴权：X-Api-Key + X-Api-Resource-Id: volc.seedasr.sauc.duration
/// 输入：Float32 PCM 16kHz mono → s16le 分帧（约 200ms/包），末包负序号（不压缩）。
/// 返回：服务端在收到最后一包后返回最终识别文本。
final class DoubaoSTTService: TranscriptionService {
    private let apiKey: String
    private let language: String?
    private let resourceID: String

    // 流式识别（实时通话）
    private var streamTask: URLSessionWebSocketTask?
    private var streamSender: StreamSender?
    private var streamResult: AsyncThrowingStream<String, Error>?
    private var streamResultContinuation: AsyncThrowingStream<String, Error>.Continuation?

    /// 保证音频帧按序发送的串行发送器
    private actor StreamSender {
        private let task: URLSessionWebSocketTask
        private var seq: Int32 = 2
        init(task: URLSessionWebSocketTask) { self.task = task }
        func feed(pcm: Data) async throws {
            var frame = Data([0x11, 0x21, 0x10, 0x00])
            var v = seq.bigEndian
            frame.append(Data(bytes: &v, count: 4))
            var len = UInt32(pcm.count).bigEndian
            frame.append(Data(bytes: &len, count: 4))
            frame.append(pcm)
            try await task.send(.data(frame))
            seq += 1
        }
        func finish() async throws {
            var frame = Data([0x11, 0x23, 0x10, 0x00])
            var v = (-seq).bigEndian
            frame.append(Data(bytes: &v, count: 4))
            var len = UInt32(0).bigEndian
            frame.append(Data(bytes: &len, count: 4))
            try await task.send(.data(frame))
        }
    }

    // MARK: - 流式识别

    func startStreaming() async throws {
        guard streamTask == nil else { return }
        let url = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()
        streamTask = task
        streamSender = StreamSender(task: task)

        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        streamResult = stream
        streamResultContinuation = cont

        // init 帧
        let payload: [String: Any] = [
            "user": ["uid": "clawtalk-ios"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
                        "enable_ddc": true, "show_utterances": false, "enable_nonstream": false]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        var frame = Data([0x11, 0x11, 0x10, 0x00])
        var seq = Int32(1).bigEndian
        frame.append(Data(bytes: &seq, count: 4))
        var len = UInt32(json.count).bigEndian
        frame.append(Data(bytes: &len, count: 4))
        frame.append(json)
        try await task.send(.data(frame))

        // 接收结果
        let resultCont = self.streamResultContinuation
        Task {
            var finalText = ""
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    if !finalText.isEmpty {
                        resultCont?.yield(finalText)
                    } else {
                        LogCollector.record(module: "语音识别", "豆包流式识别连接中断：\(AppErrorText.localized(error.localizedDescription))")
                    }
                    resultCont?.finish()
                    return
                }
                guard case .data(let data) = message else { continue }
                let parsed: (text: String?, isFinal: Bool)
                do {
                    parsed = try Self.parseResponse(data)
                } catch {
                    LogCollector.record(module: "语音识别", AppErrorText.localized(error.localizedDescription))
                    continue
                }
                if let text = parsed.text, !text.isEmpty {
                    finalText = text
                }
                if parsed.isFinal {
                    resultCont?.yield(finalText)
                    resultCont?.finish()
                    return
                }
            }
        }
    }

    func feedStreaming(samples: [Float]) async throws {
        guard let sender = streamSender, !samples.isEmpty else { return }
        let pcm = Self.samplesToPCM16(samples)
        try await sender.feed(pcm: pcm)
    }

    func finishStreaming() async throws -> String {
        guard let sender = streamSender else { return "" }
        try await sender.finish()
        var result = ""
        if let stream = streamResult {
            for try await text in stream {
                result = text
                break
            }
        }
        streamTask?.cancel(with: .goingAway, reason: nil)
        streamTask = nil
        streamSender = nil
        streamResult = nil
        streamResultContinuation = nil
        return result
    }

    func cancelStreaming() {
        streamTask?.cancel(with: .goingAway, reason: nil)
        streamTask = nil
        streamSender = nil
        streamResultContinuation?.finish()
        streamResult = nil
        streamResultContinuation = nil
    }

    init(apiKey: String, language: String? = nil, resourceID: String = "volc.seedasr.sauc.duration") {
        self.apiKey = apiKey
        self.language = language
        self.resourceID = resourceID
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard !audioSamples.isEmpty else { return "" }

        let pcm = DoubaoSTTService.samplesToPCM16(audioSamples)

        let url = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    try await Self.sendInit(task)
                    try await Self.sendAudioFrames(task, pcm: pcm)
                    let text = try await Self.receiveResults(task)
                    task.cancel(with: .goingAway, reason: nil)
                    continuation.resume(returning: text)
                } catch {
                    task.cancel(with: .goingAway, reason: nil)
                    LogCollector.record(module: "语音识别", "豆包语音识别失败：\(AppErrorText.localized(error.localizedDescription))")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 帧构造（JSON，无压缩）

    private static func sendInit(_ task: URLSessionWebSocketTask) async throws {
        let payload: [String: Any] = [
            "user": ["uid": "clawtalk-ios"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": true,
                "show_utterances": false,
                "enable_nonstream": false
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        var frame = Data([0x11, 0x11, 0x10, 0x00])
        var seq = Int32(1).bigEndian
        frame.append(Data(bytes: &seq, count: 4))
        var len = UInt32(json.count).bigEndian
        frame.append(Data(bytes: &len, count: 4))
        frame.append(json)
        try await task.send(.data(frame))
    }

    private static func sendAudioFrames(_ task: URLSessionWebSocketTask, pcm: Data) async throws {
        let chunkBytes = 16000 * 2 / 5 // 200ms
        var seq: Int32 = 2
        var index = 0
        while index < pcm.count {
            let end = min(index + chunkBytes, pcm.count)
            let chunk = pcm.subdata(in: index..<end)
            let isLast = end >= pcm.count
            var frame = Data(isLast ? [0x11, 0x23, 0x10, 0x00] : [0x11, 0x21, 0x10, 0x00])
            let seqValue = isLast ? -seq : seq
            var seqBE = seqValue.bigEndian
            frame.append(Data(bytes: &seqBE, count: 4))
            var len = UInt32(chunk.count).bigEndian
            frame.append(Data(bytes: &len, count: 4))
            frame.append(chunk)
            try await task.send(.data(frame))
            seq += 1
            index = end
        }
    }

    private static func receiveResults(_ task: URLSessionWebSocketTask) async throws -> String {
        var finalText = ""
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // 服务端发完最终结果后正常关闭连接，返回已累积的文本
                return finalText
            }
            switch message {
            case .data(let data):
                let parsed = try parseResponse(data)
                if let text = parsed.text, !text.isEmpty {
                    finalText = text
                }
                if parsed.isFinal {
                    return finalText
                }
            case .string(let string):
                let err = DoubaoSTTError.serverMessage(string)
                LogCollector.record(module: "语音识别", AppErrorText.localized(err.localizedDescription))
                throw err
            @unknown default:
                break
            }
        }
    }

    private static func parseResponse(_ data: Data) throws -> (text: String?, isFinal: Bool) {
        guard data.count >= 4 else { throw DoubaoSTTError.malformedFrame }
        let msgType = (data[1] >> 4) & 0x0F
        let flags = data[1] & 0x0F
        var offset = 4

        if msgType == 0b1111 {
            guard data.count >= offset + 8 else { throw DoubaoSTTError.malformedFrame }
            let code = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            offset += 4
            let bodyLen = Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            offset += 4
            guard data.count >= offset + bodyLen else { throw DoubaoSTTError.malformedFrame }
            let body = String(data: data.subdata(in: offset..<offset + bodyLen), encoding: .utf8) ?? ""
            throw DoubaoSTTError.serverError(code, body)
        }

        if flags & 0b0011 != 0 {
            guard data.count >= offset + 4 else { throw DoubaoSTTError.malformedFrame }
            offset += 4 // sequence
        }

        guard data.count >= offset + 4 else { throw DoubaoSTTError.malformedFrame }
        let payloadLen = Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        offset += 4
        guard data.count >= offset + payloadLen else { throw DoubaoSTTError.malformedFrame }
        let payload = data.subdata(in: offset..<offset + payloadLen)

        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return (nil, flags & 0b0010 != 0)
        }
        let text = result["text"] as? String
        let isFinal = (json["is_final"] as? Bool) ?? (result["is_final"] as? Bool) ?? (flags & 0b0010 != 0)
        return (text, isFinal)
    }

    /// Float32 → s16le PCM（16kHz mono）
    static func samplesToPCM16(_ samples: [Float]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, Double(sample)))
            var int16 = Int16(clamped * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &int16) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }
}

enum DoubaoSTTError: LocalizedError {
    case serverMessage(String)
    case serverError(UInt32, String)
    case malformedFrame

    var errorDescription: String? {
        switch self {
        case .serverMessage(let message):
            return "豆包 ASR 服务端返回：\(message)"
        case .serverError(let code, let message):
            return "豆包 ASR 错误(\(code))：\(message)"
        case .malformedFrame:
            return "豆包 ASR 响应格式异常"
        }
    }
}
