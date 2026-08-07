import AVFoundation

// MARK: - 语音朗读服务（系统 TTS）
/// 键盘扩展内朗读 AI 回复：AVSpeechSynthesizer + zh-CN 语音。
/// 朗读前把 AVAudioSession 切到 .playback，保证键盘进程内声音可播放。
final class SpeechSynthesizerService: NSObject {

    static let shared = SpeechSynthesizerService()

    /// 朗读状态变化通知（object = 本服务单例），用于刷新「朗读/停止」按钮
    static let speakingStateChangedNotification = Notification.Name("SpeechSynthesizerServiceSpeakingStateChanged")

    private let synthesizer = AVSpeechSynthesizer()

    private(set) var isSpeaking = false
    private(set) var currentText: String?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 朗读一段文字；正在朗读同一句时点击则停止；朗读其他句时打断并切换
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isSpeaking && currentText == trimmed {
            stop()
            return
        }
        stop()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // 音频会话设置失败不阻塞朗读（个别场景直接出声）
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        currentText = trimmed
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        currentText = nil
        updateSpeakingState(false)
    }

    private func updateSpeakingState(_ speaking: Bool) {
        guard isSpeaking != speaking else { return }
        isSpeaking = speaking
        NotificationCenter.default.post(name: Self.speakingStateChangedNotification, object: self)
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension SpeechSynthesizerService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        updateSpeakingState(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        currentText = nil
        updateSpeakingState(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        currentText = nil
        updateSpeakingState(false)
    }
}


