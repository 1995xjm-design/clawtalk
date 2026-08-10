import AVFoundation

/// 探测 iOS 物理静音键（侧边静音开关）状态。
/// iOS 无官方 API 读取静音键，采用通用探测法：
/// 用受静音键影响的 .ambient 类别播放一段静音音频，播放期间多次采样 outputVolume（静音时归 0）。
/// 探测结束后完整恢复音频会话，避免影响后续朗读。
enum MuteSwitchDetector {
    /// 当前是否处于物理静音状态（异步，避免阻塞主线程）
    static func isMuted() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        let originalCategory = session.category
        let originalMode = session.mode
        let originalOptions = session.categoryOptions
        var muted = false

        do {
            try session.setCategory(.ambient, mode: .default, options: [])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: format)

            let frameCount = AVAudioFrameCount(8820) // 0.2s 静音
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return false
            }
            buffer.frameLength = frameCount
            if let data = buffer.floatChannelData?[0] {
                memset(data, 0, Int(frameCount) * MemoryLayout<Float>.size)
            }

            try engine.start()
            player.play()
            player.scheduleBuffer(buffer)

            // 播放期间多次采样（0.6s 内），静音时 outputVolume 归 0
            let deadline = Date().addingTimeInterval(0.6)
            while Date() < deadline {
                if session.outputVolume < 0.05 {
                    muted = true
                    break
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }

            player.stop()
            engine.stop()
        } catch {
            muted = false
        }

        // 完整恢复音频会话
        try? session.setCategory(originalCategory, mode: originalMode, options: originalOptions)
        try? session.setActive(true)
        return muted
    }
}
