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
                // 跟随系统「朗读语音」设置：不显式指定 voice（显式指定会忽略系统设置）
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
