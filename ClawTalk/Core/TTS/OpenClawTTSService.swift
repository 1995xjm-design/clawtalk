import Foundation

final class OpenClawTTSService: SpeechService {
    private let backendURL: String
    private let voice: String?
    private let session: URLSession
    private var currentTask: Task<Void, Never>?

    init(backendURL: String, voice: String?) {
        self.backendURL = backendURL
        self.voice = voice
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
                        throw TTSError.httpError(status)
                    }

                    // Backend streams raw 16-bit signed integer PCM at 24kHz mono.
                    // Convert to Float32 for AudioPlaybackManager.
                    var buffer = Data()
                    let chunkSize = 4800 // 100ms of Int16 audio at 24kHz (24000 * 2 / 10 / 2)

                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        buffer.append(byte)

                        if buffer.count >= chunkSize {
                            continuation.yield(Self.int16ToFloat32(buffer))
                            buffer = Data()
                        }
                    }

                    // Flush remaining
                    if !buffer.isEmpty {
                        continuation.yield(Self.int16ToFloat32(buffer))
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

    private static func int16ToFloat32(_ data: Data) -> Data {
        let sampleCount = data.count / MemoryLayout<Int16>.size
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

    private func buildRequest(text: String) throws -> URLRequest {
        let trimmed = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: base + "/api/tts") else {
            throw TTSError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body: [String: Any] = ["text": text]
        if let voice, !voice.isEmpty {
            body["voice"] = voice
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
