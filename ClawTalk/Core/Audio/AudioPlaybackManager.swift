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
        // 修复「朗读到一段就断」：旧实现带 60s 硬上限，长回复朗读超过 60s 会被强停截断。
        // 现在不设时长上限，只在两种异常情况兜底退出，避免永久卡死：
        //  ① 从未入队任何音频（TTS 失败/空结果）——等首包最多 20s；
        //  ② 播放中 30s 无进展（播放器卡死/被系统中断）——退出等待。
        let firstPacketDeadline = Date().addingTimeInterval(20)
        var lastEnqueued = -1
        var lastCompleted = -1
        var lastProgress = Date()
        while true {
            var enqueued = 0
            var completed = 0
            var finished = false
            lock.lock()
            enqueued = buffersEnqueued
            completed = buffersCompleted
            finished = streamingDone
            lock.unlock()

            if finished {
                if enqueued == 0 || completed >= enqueued { break }
            }

            if enqueued == 0 {
                // 等首包（TTS 合成中）：20s 内应出现
                if Date() >= firstPacketDeadline { break }
            } else if enqueued != lastEnqueued || completed != lastCompleted {
                lastEnqueued = enqueued
                lastCompleted = completed
                lastProgress = Date()
            } else if Date().timeIntervalSince(lastProgress) >= 30 {
                // 有音频但 30s 无进展：判定卡死，退出避免永久等待
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Small grace period for audio output to flush
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
