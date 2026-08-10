import AVFoundation

/// 探测 iOS 物理静音键（侧边静音开关）状态。
/// iOS 无官方 API 读取静音键，采用通用探测法：
/// 用受静音键影响的 .ambient 类别播放一段极短静音音频，读取 outputVolume 是否为 0。
enum MuteSwitchDetector {
    /// 当前是否处于物理静音状态
    static func isMuted() -> Bool {
        let session = AVAudioSession.sharedInstance()
        let originalCategory = session.category
        let originalMode = session.mode
        do {
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
        } catch {
            return false
        }
        defer {
            try? session.setCategory(originalCategory, mode: originalMode)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let frameCount = AVAudioFrameCount(4410) // 0.1s
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return false
        }
        buffer.frameLength = frameCount
        if let data = buffer.floatChannelData?[0] {
            memset(data, 0, Int(frameCount) * MemoryLayout<Float>.size)
        }

        try? engine.start()
        player.play()
        player.scheduleBuffer(buffer)
        Thread.sleep(forTimeInterval: 0.18)
        player.stop()
        engine.stop()

        return session.outputVolume == 0
    }
}
