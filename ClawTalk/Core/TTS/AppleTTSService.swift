import Foundation
import AVFoundation

/// Apple ?? TTS?AVSpeechSynthesizer??
/// ??????????????????????"??????"?
/// ?????????????????? voice??????????????
final class AppleTTSService: NSObject, SpeechService, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let speed: Int
    private let pitch: Int

    private struct Item {
        let id = UUID()
        let utterance: AVSpeechUtterance
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
    }

    private var queue: [Item] = []
    private var current: Item?
    private var stopped = false

    init(speed: Int = 0, pitch: Int = 0) {
        self.speed = speed
        self.pitch = pitch
        super.init()
        synthesizer.delegate = self
    }

    func streamSpeech(text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = Float(min(max(0.5 + Double(speed) / 100.0, 0.1), 1.0))
            utterance.pitchMultiplier = Float(min(max(1.0 + Double(pitch) / 10.0, 0.5), 2.0))

            let itemID = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.cancel(itemID)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard !self.stopped else {
                    continuation.finish()
                    return
                }
                self.queue.append(Item(utterance: utterance, continuation: continuation))
                self.pump()
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.synthesizer.stopSpeaking(at: .immediate)
            if let item = self.current {
                self.current = nil
                item.continuation.finish()
            }
            let pending = self.queue
            self.queue.removeAll()
            pending.forEach { $0.continuation.finish() }
        }
    }

    /// ???? onTermination????????????????????????
    private func cancel(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.current?.id == id {
                self.current = nil
                self.synthesizer.stopSpeaking(at: .immediate)
                self.pump()
            } else if let idx = self.queue.firstIndex(where: { $0.id == id }) {
                self.queue.remove(at: idx)
            }
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate???????

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let item = current, item.utterance === utterance else { return }
        current = nil
        item.continuation.finish()
        pump()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // ????? current ?? nil?????????????
        guard let item = current, item.utterance === utterance else { return }
        current = nil
        item.continuation.finish()
        pump()
    }

    private func pump() {
        guard !stopped, current == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        current = item
        synthesizer.speak(item.utterance)
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
}
