import AVFoundation

/// 长录音录制器：AVAudioEngine + AVAudioFile 流式写盘（不堆内存），
/// 录音期间保持音频会话活跃 + 后台任务，切后台继续（依赖 App 的 audio 后台模式）。
/// 主 App 语音输入共用（VoiceInputStateMachine 持有）。
final class LongAudioRecorder {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private let writeQueue = DispatchQueue(label: "clawtalk.long-audio-write")
    private(set) var isRecording = false
    private(set) var currentLevel: Float = 0

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        try? inputNode.setVoiceProcessingEnabled(true)
    var format = inputNode.outputFormat(forBus: 0)
    // SIGABRT 防护（2026-08-15 日志 IsFormatSampleRateAndChannelCountValid false）：
    // 采样率/声道数无效时用标准 44.1kHz 单声道兜底，避免 AVAudioFile/installTap 抛 NSException。
    if format.sampleRate <= 0 || format.channelCount == 0 {
        LogCollector.record(module: "长录音", "录音输入格式异常（采样率\(format.sampleRate)/声道\(format.channelCount)），已用标准格式兜底")
        if let fallback = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) {
            format = fallback
        }
    }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        self.file = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.currentLevel = Self.instantLevel(of: buffer)
            self.writeQueue.async { [weak self] in
                guard let self, let file = self.file else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    LogCollector.record(module: "长录音", "写盘失败：\(error.localizedDescription)")
                }
            }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        isRecording = true
    }

    /// 停止录音：摘 tap → 刷完写盘队列 → 读出 16kHz 单声道 Float32 样本。
    func stop() -> [Float] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRecording = false
        currentLevel = 0
        let url = file?.url
        file = nil
        // 等写盘队列排空，避免读到未写完的文件
        writeQueue.sync {}
        guard let url else { return [] }
        defer { try? FileManager.default.removeItem(at: url) }
        return readSamples16k(from: url)
    }

    // MARK: - 工具

    private static func instantLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Double = 0
        let count = Int(buffer.frameLength)
        for i in 0..<count {
            let v = Double(data[i])
            sum += v * v
        }
        return Float(sqrt(sum / Double(count)))
    }

    private func readSamples16k(from url: URL) -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            return []
        }
        do {
            try audioFile.read(into: buffer)
        } catch {
            return []
        }
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        let captured = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return Self.resampleTo16k(captured, from: audioFile.processingFormat.sampleRate)
    }

    private static func resampleTo16k(_ samples: [Float], from sampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let outputRate = 16000.0
        if abs(sampleRate - outputRate) < 0.5 {
            return samples
        }
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return samples
        }
        let ratio = outputRate / sampleRate
        let outputLength = Int(Double(samples.count) * ratio)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outputLength)) else {
            return samples
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            inputBuffer.floatChannelData?[0].update(from: base, count: samples.count)
        }
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            status.pointee = .haveData
            return inputBuffer
        }
        guard error == nil else { return samples }
        return Array(UnsafeBufferPointer(start: outputBuffer.floatChannelData?[0], count: Int(outputBuffer.frameLength)))
    }
}