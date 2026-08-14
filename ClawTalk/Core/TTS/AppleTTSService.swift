import Foundation
import AVFoundation

/// Apple 系统 TTS：AVSpeechSynthesizer 朗读。
/// 支持打断/继续；被打断后再次朗读会自动复位（见 streamSpeech）。
/// 长文自动按句分段成多个 utterance 顺序朗读（段间由 didFinish/didCancel 续接），
/// 避免单个超长 utterance 被系统中途静默截断（S7：长文朗读到一段自己断掉）。
/// 音色/语速/音调由设置传入，跟随系统语音。
final class AppleTTSService: NSObject, SpeechService, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let speed: Int
    private let pitch: Int

    /// 单段最长字符数：超过即按标点/字符数兜底分段，防止 AVSpeechUtterance 过长。
    private static let maxSegmentLength = 180

    private final class Item {
        let id = UUID()
        let utterances: [AVSpeechUtterance]
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
        var nextIndex = 0

        init(utterances: [AVSpeechUtterance], continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            self.utterances = utterances
            self.continuation = continuation
        }
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
        // 复位粘滞标记：被打断后再次朗读必须能出声（S6 发现）
        stopped = false
        return AsyncThrowingStream { continuation in
            let segments = AppleTTSService.segments(from: text)
            guard !segments.isEmpty else {
                continuation.finish()
                return
            }

            let utterances = segments.map { segment -> AVSpeechUtterance in
                let utterance = AVSpeechUtterance(string: segment)
                utterance.rate = Float(min(max(0.5 + Double(self.speed) / 100.0, 0.1), 1.0))
                utterance.pitchMultiplier = Float(min(max(1.0 + Double(self.pitch) / 10.0, 0.5), 2.0))
                return utterance
            }

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
                self.queue.append(Item(utterances: utterances, continuation: continuation))
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

    /// 消费者取消流（onTermination）：只清理「自己的」条目，不误杀其他朗读。
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

    // MARK: - AVSpeechSynthesizerDelegate（均在主线程回调）

    /// 一段读完后自动续读下一段；全部读完才结束流。
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let item = current, item.utterances.contains(where: { $0 === utterance }) else { return }
        current = nil
        pump()
    }

    /// 被系统意外取消（音频会话被抢占等）时续读下一段，保证长文朗读不中断；
    /// 用户主动 stop 时 stopped=true，pump 直接返回，不会续读。
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard let item = current, item.utterances.contains(where: { $0 === utterance }) else { return }
        current = nil
        pump()
    }

    private func pump() {
        guard !stopped, current == nil, !queue.isEmpty else { return }
        guard let head = queue.first, head.nextIndex < head.utterances.count else {
            // 当前条目全部分段已读完：结束该流，继续下一个条目。
            let finished = queue.removeFirst()
            finished.continuation.finish()
            pump()
            return
        }
        let utterance = head.utterances[head.nextIndex]
        head.nextIndex += 1
        current = head
        synthesizer.speak(utterance)
    }

    /// 长文分段：按句末标点切分（。！？；…\n 等），超长无标点段按字符数兜底硬切。
    /// 分段后逐段朗读并续接，保证长文朗读不中断、不截断。
    static func segments(from text: String, maxLength: Int = AppleTTSService.maxSegmentLength) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let terminators: [Character] = ["。", "！", "？", "；", ".", "!", "?", ";", "\n", "\r"]
        var segments: [String] = []
        var current = ""

        func flush() {
            let segment = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty { segments.append(segment) }
            current = ""
        }

        for character in trimmed {
            current.append(character)
            if terminators.contains(character) {
                flush()
            } else if current.count >= maxLength {
                flush()
            }
        }
        flush()
        return segments
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
