import AVFoundation

final class AudioPlaybackManager: @unchecked Sendable {
    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private(set) var isPlaying = false
    private var buffersEnqueued = 0
    private var buffersCompleted = 0
    private var streamingDone = false
    private var mixerNode: AVAudioMixerNode?
    private var isDucked = false

    private var started = false

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // Preserve .voiceChat if AudioCaptureManager already set it for
        // conversation mode — that mode's AEC is what stops TTS from
        // looping back through the mic loud enough to cross the
        // interrupt threshold and cancel the agent's response.
        let mode: AVAudioSession.Mode = (session.mode == .voiceChat) ? .voiceChat : .default
        try session.setCategory(.playAndRecord, mode: mode, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()

        engine.attach(player)
        engine.attach(mixer)
        engine.connect(player, to: mixer, format: playbackFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: playbackFormat)
        mixer.outputVolume = 1.0
        engine.prepare()
        try engine.start()

        lock.lock()
        audioEngine = engine
        playerNode = player
        mixerNode = mixer
        isPlaying = true
        buffersEnqueued = 0
        buffersCompleted = 0
        streamingDone = false
        started = false
        lock.unlock()
    }

    /// Schedule a chunk of PCM audio (Float32, 24kHz, mono) for playback.
    func enqueue(pcmData: Data) {
        guard let player = playerNode else { return }

        let sampleCount = pcmData.count / MemoryLayout<Float>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        pcmData.withUnsafeBytes { raw in
            if let src = raw.baseAddress?.assumingMemoryBound(to: Float.self) {
                buffer.floatChannelData?[0].update(from: src, count: sampleCount)
            }
        }

        lock.lock()
        buffersEnqueued += 1
        let shouldStart = !started
        if shouldStart { started = true }
        lock.unlock()

        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.buffersCompleted += 1
            self.lock.unlock()
        }
        // 首个 buffer 到达即播放（首音快）。
        // TTS 合成慢于播放时，播放队列可能出现空窗导致 AVAudioPlayerNode 停止，
        // 之后入队的 buffer 不会自动续播 → 表现为「朗读到一段就断」。
        // 因此每次入队都检查：已不在播放则立即恢复。
        if shouldStart || !player.isPlaying {
            player.play()
        }
    }

    /// Signal that no more buffers will be enqueued.
    func markStreamingDone() {
        lock.lock()
        streamingDone = true
        lock.unlock()
    }

    func stop() {
        playerNode?.stop()
        audioEngine?.stop()
        lock.lock()
        audioEngine = nil
        playerNode = nil
        mixerNode = nil
        isPlaying = false
        isDucked = false
        buffersEnqueued = 0
        buffersCompleted = 0
        streamingDone = false
        started = false
        lock.unlock()
    }

    // MARK: - Ducking

    func duckVolume() {
        guard !isDucked, let mixer = mixerNode else { return }
        isDucked = true
        mixer.outputVolume = 0.3
    }

    func restoreVolume() {
        guard isDucked, let mixer = mixerNode else { return }
        isDucked = false
        mixer.outputVolume = 1.0
    }

    /// Wait until all enqueued audio has finished playing.
    func waitUntilFinished() async {
        // 兜底超时：避免播放完成回调丢失/无音频入队时永久卡死（卡死会阻塞整个发送流程）
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            lock.lock()
            let enqueued = buffersEnqueued
            let done = streamingDone && enqueued > 0 && buffersCompleted >= enqueued
            let empty = streamingDone && enqueued == 0
            lock.unlock()
            if done || empty { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Small grace period for audio output to flush
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
