import Foundation
import Speech
import AVFoundation
import OSLog

/// On-device keyword detection using SFSpeechRecognizer.
/// The agent can configure wake words; when detected, a callback fires.
@Observable
@MainActor
final class VoiceWakeCapability {

    struct Config: Codable {
        var keywords: [String]
        var enabled: Bool
        var locale: String
    }

    struct ConfigResult: Encodable {
        let keywords: [String]
        let enabled: Bool
        let locale: String
    }

    enum VoiceWakeError: LocalizedError {
        case denied
        case unavailable
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .denied: return "语音识别权限被拒绝"
            case .unavailable: return "语音识别不可用"
            case .alreadyRunning: return "语音唤醒已在运行"
            }
        }
    }

    // MARK: - State

    private(set) var isListening = false
    private(set) var currentKeywords: [String] = []
    var onKeywordDetected: ((String) -> Void)?
    /// 检测到唤醒词后是否自动重启监听。Node端（智能体）控制时保持 true；App端免提对话会先置 false，避免重启后与对话模式抢麦克风。
    var autoRestartsAfterDetection = true

    private let logger = Logger(subsystem: "com.openclaw.clawtalk", category: "voice-wake")
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    // MARK: - Singleton

    static let shared = VoiceWakeCapability()
    private init() {}


    // MARK: - Locale

    /// Resolve the speech recognition locale: honor an explicit value, otherwise
    /// follow the system language (Chinese systems -> zh-CN). If the resolved locale
    /// has no recognizer, startListening falls back to zh-CN.
    private static func resolveLocale(_ locale: String?) -> String {
        let raw = locale?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            return AppleTTSService.normalizedVoiceLanguage(raw)
        }
        let system = Locale.preferredLanguages.first ?? Locale.current.identifier
        return AppleTTSService.normalizedVoiceLanguage(system)
    }
    // MARK: - Commands

    func setConfig(keywords: [String], enabled: Bool, locale: String?) async throws -> ConfigResult {
        currentKeywords = keywords
        let resolvedLocale = Self.resolveLocale(locale)

        if enabled && !keywords.isEmpty {
            do {
                try await startListening(locale: resolvedLocale)
            } catch {
                LogCollector.record(module: "语音唤醒", AppErrorText.localized(error.localizedDescription))
                throw error
            }
        } else {
            stopListening()
        }

        return ConfigResult(
            keywords: currentKeywords,
            enabled: isListening,
            locale: resolvedLocale
        )
    }

    func getConfig() -> ConfigResult {
        ConfigResult(
            keywords: currentKeywords,
            enabled: isListening,
            locale: recognizer?.locale.identifier ?? Self.resolveLocale(nil)
        )
    }

    // MARK: - Listening

    private func startListening(locale: String) async throws {
        guard !isListening else { throw VoiceWakeError.alreadyRunning }

        // Request speech recognition permission
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authStatus == .authorized else { throw VoiceWakeError.denied }

        // Request microphone permission
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else { throw VoiceWakeError.denied }

        guard let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
              ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              speechRecognizer.isAvailable else {
            throw VoiceWakeError.unavailable
        }

        recognizer = speechRecognizer
        speechRecognizer.supportsOnDeviceRecognition = true

        // 显式配置音频会话：playAndRecord 保证退后台后音频引擎持续运行（Info.plist 已开 UIBackgroundModes=audio）
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? audioSession.setActive(true)

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()

        let lowercaseKeywords = currentKeywords.map { $0.lowercased() }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    for keyword in lowercaseKeywords {
                        if text.contains(keyword) {
                            self.logger.info("wake keyword detected: \(keyword, privacy: .public)")
                            self.onKeywordDetected?(keyword)
                            // Restart to clear buffer (agent-controlled); app mode stays stopped
                            self.stopListening()
                            guard self.autoRestartsAfterDetection else { return }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            try? await self.startListening(locale: locale)
                            return
                        }
                    }
                }

                if let error {
                    self.logger.error("voice wake error: \(error.localizedDescription, privacy: .public)")
                    LogCollector.record(module: "语音唤醒", AppErrorText.localized(error.localizedDescription))
                    self.stopListening()
                    // 监听被系统中断（如来电/其他 App 占用音频）后按配置自动重启，保证后台持续监听
                    guard self.autoRestartsAfterDetection else { return }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    try? await self.startListening(locale: locale)
                }
            }
        }

        audioEngine = engine
        recognitionRequest = request
        isListening = true
        logger.info("voice wake started, keywords: \(self.currentKeywords)")
    }

    // MARK: - Keyword Helpers

    /// 规范化唤醒词列表：去空白、去空词、按大小写去重，保证给识别引擎的 keywords 干净有效。
    static func normalizedKeywords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    func stopListening() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        logger.info("voice wake stopped")
    }
}

// MARK: - Params

struct VoiceWakeSetParams: Decodable {
    let keywords: [String]?
    let enabled: Bool?
    let locale: String?
}

// MARK: - Wake Word Notification

extension Notification.Name {
    static let clawTalkWakeWordDetected = Notification.Name("ClawTalkWakeWordDetected")
    static let clawTalkWakeRestartRequested = Notification.Name("ClawTalkWakeRestartRequested")
}
