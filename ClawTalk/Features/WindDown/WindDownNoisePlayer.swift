import AVFoundation
import Foundation

/// 睡前白噪音播放器：AVAudioEngine + AVAudioSourceNode 生成固定白噪音循环。
/// 纯代码生成、无外部资源；stop() 立即停止并释放引擎。
/// 会话沿用 AudioPlaybackManager 同一套（.playAndRecord + defaultToSpeaker），
/// 避免与「说晚安」TTS 播放互相打断。
@MainActor
final class WindDownNoisePlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    /// 定时剩余分钟数（nil = 未定时，手动停止）
    @Published private(set) var remainingMinutes: Int?

    private var engine: AVAudioEngine?
    private var timerTask: Task<Void, Never>?

    /// 开始播放白噪音。volume 为 0~1 的幅度（默认 0.05，很轻，适合睡前）。
    func start(volume: Float = 0.05) {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            let mode: AVAudioSession.Mode = (session.mode == .voiceChat) ? .voiceChat : .default
            try session.setCategory(.playAndRecord, mode: mode, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            LogCollector.record(module: "睡前陪伴", "白噪音会话启动失败：\(AppErrorText.localized(error.localizedDescription))")
            return
        }

        let newEngine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                guard let mData = buffer.mData else { continue }
                let frames = Int(frameCount)
                let channelCount = Int(buffer.mNumberChannels)
                let samples = mData.assumingMemoryBound(to: Float.self)
                let total = frames * channelCount
                for index in 0..<total {
                    samples[index] = Float.random(in: -1...1) * volume
                }
            }
            return noErr
        }
        let mixer = AVAudioMixerNode()
        mixer.outputVolume = 0.9
        newEngine.attach(source)
        newEngine.attach(mixer)
        newEngine.connect(source, to: mixer, format: format)
        newEngine.connect(mixer, to: newEngine.mainMixerNode, format: format)
        newEngine.mainMixerNode.outputVolume = 0.8
        try? newEngine.start()
        engine = newEngine
        isPlaying = true
    }

    /// 定时播放：minutes 分钟后自动停止（手动停止同样生效）。
    func startTimed(minutes: Int, volume: Float = 0.05) {
        start(volume: volume)
        guard isPlaying else { return }
        timerTask?.cancel()
        remainingMinutes = minutes
        timerTask = Task { @MainActor in
            for remaining in stride(from: minutes, through: 1, by: -1) {
                try? await Task.sleep(nanoseconds: UInt64(60 * 1_000_000_000))
                if Task.isCancelled { return }
                remainingMinutes = remaining - 1
            }
            stop()
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        remainingMinutes = nil
        engine?.stop()
        engine = nil
        isPlaying = false
    }
}