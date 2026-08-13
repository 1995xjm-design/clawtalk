import Foundation
import Speech
import AVFoundation

/// 使用 iOS 系统自带语音识别（SFSpeechRecognizer）。
/// - 支持中文（zh-CN），无需下载 Whisper 模型；
/// - 默认走苹果在线识别（联网更准、无需下载离线包）；
/// - 可选 allowOnDevice：仅在其启用时才尝试离线识别，失败自动回退在线。
final class AppleSTTService: TranscriptionService {
    private let recognizer: SFSpeechRecognizer?
    private let language: String?
    private let allowOnDevice: Bool

    /// 识别超时（秒）：整个识别过程的上限，超时自动取消任务并抛「识别超时」。
    private static let recognitionTimeout: TimeInterval = 20
    /// 静音检测阈值（RMS）：正常说话 vs 安静环境的合理边界，可调常量。
    private static let silenceRMSThreshold: Float = 0.01

    init(language: String? = nil, allowOnDevice: Bool = false) {
        self.language = language
        self.allowOnDevice = allowOnDevice
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
        // 0) 静音检测：转写前先算音量，没声音直接抛错
        if Self.rmsLevel(of: audioSamples) < Self.silenceRMSThreshold {
            throw AppleSTTError.noSpeech
        }

        // 1) 权限
        try await ensureAuthorization()

        // 2) 识别器可用性
        guard let recognizer, recognizer.isAvailable else {
            throw AppleSTTError.unavailable
        }

        // 3) Float32 PCM (16kHz mono) -> WAV 临时文件
        let wavURL = try Self.writeWAV(samples: audioSamples)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // 4) 识别：默认在线；allowOnDevice 时先离线、失败回退在线；全程 20 秒超时兜底
        let box = RecognitionTaskBox()
        let text = try await Self.runRecognition(
            wavURL: wavURL,
            recognizer: recognizer,
            allowOnDevice: allowOnDevice,
            box: box
        )
        return TranscriptCleanup.clean(text)
    }

    // MARK: - 识别（超时 + 离线回退）

    private static func runRecognition(
        wavURL: URL,
        recognizer: SFSpeechRecognizer,
        allowOnDevice: Bool,
        box: RecognitionTaskBox
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group -> String in
            // 识别子任务：可离线 -> 在线回退
            group.addTask {
                let request = SFSpeechURLRecognitionRequest(url: wavURL)
                request.shouldReportPartialResults = false

                guard allowOnDevice, recognizer.supportsOnDeviceRecognition else {
                    return try await Self.performRequest(request, recognizer: recognizer, box: box)
                }

                request.requiresOnDeviceRecognition = true
                do {
                    let offlineText = try await Self.performRequest(request, recognizer: recognizer, box: box)
                    if !offlineText.isEmpty {
                        return offlineText
                    }
                } catch {
                    // 离线识别失败 → 回退在线，不卡死
                }

                let onlineRequest = SFSpeechURLRecognitionRequest(url: wavURL)
                onlineRequest.shouldReportPartialResults = false
                return try await Self.performRequest(onlineRequest, recognizer: recognizer, box: box)
            }

            // 超时子任务：20 秒倒计时，超时取消识别并抛错
            group.addTask {
                try await Task.sleep(for: .seconds(Self.recognitionTimeout))
                box.task?.cancel()
                throw AppleSTTError.timeout
            }

            defer { box.task?.cancel() }

            guard let first = try await group.next() else {
                throw AppleSTTError.unavailable
            }
            group.cancelAll()
            return first
        }
    }

    private static func performRequest(
        _ request: SFSpeechURLRecognitionRequest,
        recognizer: SFSpeechRecognizer,
        box: RecognitionTaskBox
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 静音检测

    /// 计算音频样本的 RMS（均方根音量），用于判断是否有有效人声。
    private static func rmsLevel(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples {
            sum += Double(sample) * Double(sample)
        }
        return Float(sqrt(sum / Double(samples.count)))
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

/// 识别任务引用容器：超时或外部取消时用于取消底层 SFSpeechRecognitionTask。
private final class RecognitionTaskBox {
    var task: SFSpeechRecognitionTask?
}

enum AppleSTTError: LocalizedError {
    case permissionDenied
    case unavailable
    case timeout
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "语音识别权限被拒绝，请在设置中开启"
        case .unavailable:
            return "语音识别不可用"
        case .timeout:
            return "识别超时，请再说一遍试试"
        case .noSpeech:
            return "没听到声音，请靠近麦克风再试"
        }
    }
}
