import Foundation
import AVFoundation

final class AppleTTSService: NSObject, SpeechService, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var completionHandler: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func streamSpeech(text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = Self.voiceForSystemLanguage()
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate

                self.completionHandler = {
                    continuation.finish()
                }

                continuation.onTermination = { [weak self] _ in
                    self?.synthesizer.stopSpeaking(at: .immediate)
                    self?.completionHandler = nil
                }

                self.synthesizer.speak(utterance)
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        completionHandler?()
        completionHandler = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        completionHandler?()
        completionHandler = nil
    }

    // MARK: - Voice Selection

    /// Pick a voice matching the system language so Chinese systems speak Chinese
    /// instead of always using English. Falls back to Chinese (zh-CN) when no voice exists.
    private static func voiceForSystemLanguage() -> AVSpeechSynthesisVoice? {
        let systemLanguage = Locale.preferredLanguages.first ?? Locale.current.identifier
        let voiceLanguage = normalizedVoiceLanguage(systemLanguage)
        return AVSpeechSynthesisVoice(language: voiceLanguage) ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    /// AVSpeechSynthesisVoice expects region-style codes (e.g. "zh-CN"), while system
    /// locales can carry a script (e.g. "zh-Hans-CN"). Normalize to the region form.
    static func normalizedVoiceLanguage(_ language: String) -> String {
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        let locale = Locale(identifier: normalized)
        guard locale.languageCode?.lowercased() == "zh" else { return normalized }
        if let region = locale.regionCode {
            return "zh-\(region)"
        }
        return "zh-CN"
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        completionHandler?()
        completionHandler = nil
    }
}
