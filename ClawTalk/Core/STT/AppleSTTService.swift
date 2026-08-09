import Foundation
import Speech
import AVFoundation

/// 使用 iOS 系统自带语音识别（SFSpeechRecognizer）。
/// - 支持中文（zh-CN），无需下载 Whisper 模型；
/// - iOS 17+ 支持完全离线识别（on-device）。
final class AppleSTTService: TranscriptionService {
    private let recognizer: SFSpeechRecognizer?
    private let language: String?

    init(language: String? = nil) {
        self.language = language
        // 优先按用户选择语言（如 zh），否则跟随系统语言
        let localeID: String
        if let language, !language.isEmpty, language != "auto" {
            localeID = Self.normalizedLocaleID(language)
        } else {
            localeID = Self.normalizedLocaleID(Locale.preferredLanguages.first ?? "zh-CN")
        }
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        // 1) 权限
        try await ensureAuthorization()

        // 2) 识别器可用性
        guard let recognizer, recognizer.isAvailable else {
            throw AppleSTTError.unavailable
        }

        // 3) Float32 PCM (16kHz mono) -> WAV 临时文件
        let wavURL = try Self.writeWAV(samples: audioSamples)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // 4) URL 识别请求（离线优先）
        let request = SFSpeechURLRecognitionRequest(url: wavURL)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let text = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    cont.resume(throwing: error)
                }
            }
        }
        return TranscriptCleanup.clean(text)
    }

    // MARK: - 权限

    private func ensureAuthorization() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
            if !granted {
                throw AppleSTTError.permissionDenied
            }
        default:
            throw AppleSTTError.permissionDenied
        }
    }

    // MARK: - WAV 转换

    private static func writeWAV(samples: [Float]) throws -> URL {
        // 16kHz 单声道 16-bit PCM
        let sampleRate = 16000
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, Double(sample)))
            let int16 = Int16(clamped * Double(Int16.max))
            withUnsafeBytes(of: int16.littleEndian) { pcm.append(contentsOf: $0) }
        }

        var header = Data()
        func appendString(_ s: String) { header.append(contentsOf: s.utf8) }
        func appendUInt32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func appendUInt16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }

        let dataSize = UInt32(pcm.count)
        let fileSize = 36 + dataSize

        appendString("RIFF")
        appendUInt32(fileSize)
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)          // fmt chunk size
        appendUInt16(1)           // PCM
        appendUInt16(1)           // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate) * 2) // byte rate
        appendUInt16(2)           // block align
        appendUInt16(16)          // bits per sample
        appendString("data")
        appendUInt32(dataSize)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        var data = header
        data.append(pcm)
        try data.write(to: url)
        return url
    }

    private static func normalizedLocaleID(_ id: String) -> String {
        let normalized = id.replacingOccurrences(of: "_", with: "-")
        let locale = Locale(identifier: normalized)
        guard locale.languageCode?.lowercased() == "zh" else { return "zh-CN" }
        if let region = locale.regionCode {
            return "zh-\(region)"
        }
        return "zh-CN"
    }
}

enum AppleSTTError: LocalizedError {
    case permissionDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "请在设置中允许 ClawTalk 使用语音识别权限（设置-隐私与安全性-语音识别）。"
        case .unavailable:
            return "系统语音识别当前不可用，请检查网络或稍后重试。"
        }
    }
}
