import Foundation
import CryptoKit
import AudioToolbox

/// Edge TTS（微软 Edge 免费接口，无需 API Key）。
///
/// 协议要点（2026-08-11 线上实测，详见 outputs/edge-tts-protocol-test.md）：
///   WSS: wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1
///        ?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4&ConnectionId=<uuid>&Sec-MS-GEC=<token>&Sec-MS-GEC-Version=1-143.0.3650.75
///   Sec-MS-GEC 必须放 URL 查询参数（放请求头会被 403 拒绝）：
///     时间戳 = Unix 秒 + 11644473600（Windows 文件时间起点），向下取整到 5 分钟，
///     再 × 10,000,000 转成 100ns 计数，拼上 TrustedClientToken 后做 SHA256，十六进制大写。
///   Origin: https://edge.microsoft.com（实测可用）
///   连上后先发文本帧 speech.config，再发文本帧 SSML。
///   返回：二进制帧 = 前 2 字节头长度（大端）+ 头 + MP3 数据；文本帧 Path:turn.end 表示结束。
///   输出：MP3（24kHz 48kbps mono）→ 整段解码成 Float32 24kHz mono PCM，再按 100ms 分块输出。
final class EdgeTTSService: SpeechService {
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let secMsGecVersion = "1-143.0.3650.75"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0"

    private let voiceID: String
    private let speed: Int
    private let pitch: Int

    private var webSocketTask: URLSessionWebSocketTask?
    private var isStopped = false
    private let lock = NSLock()

    init(voiceID: String, speed: Int = 0, pitch: Int = 0) {
        self.voiceID = voiceID
        self.speed = speed
        self.pitch = pitch
    }

    func streamSpeech(text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let requestID = EdgeTTSService.connectionID()
            let url = EdgeTTSService.endpointURL(connectionID: EdgeTTSService.connectionID())
            var request = URLRequest(url: url)
            request.setValue("https://edge.microsoft.com", forHTTPHeaderField: "Origin")
            request.setValue(EdgeTTSService.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("muid=\(EdgeTTSService.connectionID().uppercased());", forHTTPHeaderField: "Cookie")

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: request)
            self.lock.lock()
            self.webSocketTask = task
            self.isStopped = false
            self.lock.unlock()

            task.resume()

            // 先发 speech.config，再发 SSML（WebSocket 保证发送顺序）
            task.send(.string(EdgeTTSService.speechConfigFrame())) { error in
                if let error {
                    continuation.finish(throwing: error)
                }
            }
            task.send(.string(self.ssmlFrame(text: text, voiceID: self.voiceID, requestID: requestID))) { error in
                if let error {
                    continuation.finish(throwing: error)
                }
            }

            var mp3Data = Data()

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
                        case .string(let string):
                            if string.contains("turn.end") {
                                self.finishWithMP3(mp3Data, continuation: continuation)
                            } else {
                                // turn.start / response（音频元数据）等忽略，继续收
                                receive()
                            }
                        case .data(let data):
                            if let audio = self.extractAudioPayload(from: data) {
                                mp3Data.append(audio)
                            }
                            receive()
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

    /// 二进制帧：前 2 字节 = 头长度（大端），去掉头后是 MP3 音频数据。
    private func extractAudioPayload(from data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let headerLength = (Int(data[0]) << 8) | Int(data[1])
        guard data.count >= 2 + headerLength else { return nil }
        return data.subdata(in: (2 + headerLength)..<data.count)
    }

    private func finishWithMP3(_ mp3Data: Data, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        guard !mp3Data.isEmpty else {
            continuation.finish(throwing: EdgeTTSError.emptyAudio)
            return
        }
        do {
            let pcm = try EdgeTTSService.decodeMP3ToFloat32PCM(mp3Data)
            guard !pcm.isEmpty else {
                continuation.finish(throwing: EdgeTTSError.emptyAudio)
                return
            }
            // 按 100ms（2400 帧 = 9600 字节 Float32）分块输出给播放器
            let chunkSize = 9600
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + chunkSize, pcm.count)
                continuation.yield(pcm.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    // MARK: - 帧构造

    private static func endpointURL(connectionID: String) -> URL {
        var components = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "ConnectionId", value: connectionID),
            URLQueryItem(name: "Sec-MS-GEC", value: generateSecMsGec()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: secMsGecVersion)
        ]
        return components.url!
    }

    private static func speechConfigFrame() -> String {
        let config = "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}"
        return "X-Timestamp:\(timestampString())\r\n" +
            "Content-Type:application/json; charset=utf-8\r\n" +
            "Path:speech.config\r\n\r\n" + config
    }

    private func ssmlFrame(text: String, voiceID: String, requestID: String) -> String {
        let escaped = sanitize(text)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let rate = speed >= 0 ? "+\(speed)%" : "\(speed)%"
        let pitchValue = pitch >= 0 ? "+\(pitch)Hz" : "\(pitch)Hz"
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>" +
            "<voice name='\(voiceID)'><prosody pitch='\(pitchValue)' rate='\(rate)' volume='+0%'>\(escaped)</prosody></voice></speak>"
        // 注意：X-Timestamp 末尾的 Z 是微软接口的已知行为（edge-tts 注释 "This is not a mistake"），照抄
        return "X-RequestId:\(requestID)\r\n" +
            "Content-Type:application/ssml+xml\r\n" +
            "X-Timestamp:\(timestampString())Z\r\n" +
            "Path:ssml\r\n\r\n" + ssml
    }

    /// 生成 Sec-MS-GEC（必须放 URL 查询参数）。
    /// 算法：Windows 文件时间（Unix 秒 + 11644473600）向下取整到 5 分钟，
    /// 再 × 10,000,000 转成 100ns 计数，拼上 TrustedClientToken 后 SHA256，十六进制大写。
    private static func generateSecMsGec() -> String {
        var ticks = Date().timeIntervalSince1970 + 11_644_473_600.0
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        let hashInput = "\(Int64(ticks * 10_000_000))\(trustedClientToken)"
        let digest = SHA256.hash(data: Data(hashInput.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// 与 edge-tts 的 date_to_string() 一致（%a %b %d %Y %H:%M:%S GMT+0000 (Coordinated Universal Time)）。
    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private static func connectionID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// 剔除 XML 1.0 不允许的字符（控制字符会让 Edge 接口报错，与 edge-tts 的 remove_incompatible_characters 一致）。
    private static func sanitize(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let allowed = v == 0x09 || v == 0x0A || v == 0x0D
                || (v >= 0x20 && v <= 0xD7FF)
                || (v >= 0xE000 && v <= 0xFFFD)
                || (v >= 0x10000 && v <= 0x10FFFF)
            if allowed {
                result.append(scalar)
            }
        }
        return String(result)
    }

    // MARK: - MP3 解码

    /// MP3 → Float32 24kHz mono PCM（用 ExtAudioFile 自动完成采样率/声道转换）。
    private static func decodeMP3ToFloat32PCM(_ mp3Data: Data) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-tts-\(UUID().uuidString).mp3")
        try mp3Data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var extFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(tempURL as CFURL, &extFile)
        guard status == noErr, let file = extFile else {
            throw EdgeTTSError.mp3DecodeFailed(status)
        }
        defer { ExtAudioFileDispose(file) }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: 24_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard status == noErr else { throw EdgeTTSError.mp3DecodeFailed(status) }

        var out = Data()
        let framesPerSlice: UInt32 = 2400 // 100ms
        while true {
            var sliceFrames: UInt32 = framesPerSlice
            // 指针只在这段闭包内使用（避免数组重分配导致悬垂指针）
            var samples = [Float](repeating: 0, count: Int(framesPerSlice))
            let readStatus: OSStatus = samples.withUnsafeMutableBytes { raw in
                var bufferList = AudioBufferList()
                bufferList.mNumberBuffers = 1
                bufferList.mBuffers.mNumberChannels = 1
                bufferList.mBuffers.mDataByteSize = UInt32(framesPerSlice) * UInt32(MemoryLayout<Float>.size)
                bufferList.mBuffers.mData = raw.baseAddress
                return ExtAudioFileRead(file, &sliceFrames, &bufferList)
            }
            status = readStatus
            guard status == noErr else { throw EdgeTTSError.mp3DecodeFailed(status) }
            guard sliceFrames > 0 else { break }

            let validBytes = Int(sliceFrames) * MemoryLayout<Float>.size
            samples.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    out.append(base.assumingMemoryBound(to: UInt8.self), count: validBytes)
                }
            }
            if sliceFrames < framesPerSlice { break }
        }
        return out
    }
}

enum EdgeTTSError: LocalizedError {
    case emptyAudio
    case mp3DecodeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "Edge TTS 未返回音频"
        case .mp3DecodeFailed(let status):
            return "Edge TTS 音频解码失败(\(status))"
        }
    }
}
