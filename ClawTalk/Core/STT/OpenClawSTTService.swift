import Foundation

enum STTError: LocalizedError {
    case httpError(Int)
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "STT service returned HTTP \(code)."
        case .invalidConfiguration: return "STT is not configured. Check Settings."
        }
    }
}

final class OpenClawSTTService: TranscriptionService {
    private let backendURL: String
    private let language: String?
    private let session: URLSession

    init(backendURL: String, language: String?) {
        self.backendURL = backendURL
        self.language = language
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        let wavData = encodeWAV(samples: audioSamples, sampleRate: 16000)
        let request = try buildRequest(wavData: wavData)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw STTError.httpError(status)
        }

        struct TranscriptionResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }

    private func buildRequest(wavData: Data) throws -> URLRequest {
        let trimmed = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: base + "/api/stt") else {
            throw STTError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body: [String: Any] = [
            "audio_base64": wavData.base64EncodedString()
        ]
        if let language, !language.isEmpty {
            body["language"] = language
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func encodeWAV(samples: [Float], sampleRate: Int) -> Data {
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = Int32(sampleRate * Int(numChannels) * Int(bitsPerSample / 8))
        let blockAlign = Int16(numChannels * (bitsPerSample / 8))
        let dataSize = Int32(samples.count * Int(bitsPerSample / 8))
        let chunkSize = 36 + dataSize

        var data = Data()
        data.append("RIFF")
        data.appendLittleEndian(chunkSize)
        data.append("WAVE")
        data.append("fmt ")
        data.appendLittleEndian(Int32(16)) // subchunk1 size
        data.appendLittleEndian(Int16(1))  // PCM format
        data.appendLittleEndian(numChannels)
        data.appendLittleEndian(Int32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append("data")
        data.appendLittleEndian(dataSize)

        // Convert Float32 [-1, 1] to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            data.appendLittleEndian(int16)
        }

        return data
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<T>.size))
    }
}
