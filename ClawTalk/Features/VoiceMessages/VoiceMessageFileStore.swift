import Foundation

/// 语音消息本地存储：把录音采样（PCM Float32 16kHz mono）编码为 WAV 文件存入 Application Support。
///
/// WAV 采用与后端 /api/stt 相同的 16kHz 16bit 单声道 PCM，AVAudioPlayer 可直接播放，
/// 无需引入任何第三方音频库。
enum VoiceMessageFileStore {

    static func directory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ClawTalk/VoiceMessages", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 保存一条语音消息：采样 → WAV 文件，返回附件信息。
    static func save(samples: [Float], duration: TimeInterval, transcript: String) throws -> VoiceMessageAttachment {
        let name = "voice-\(UUID().uuidString.prefix(8).lowercased()).wav"
        let url = try directory().appendingPathComponent(name)
        try wavData(samples: samples).write(to: url, options: .atomic)
        return VoiceMessageAttachment(
            id: UUID(),
            localFileURL: url,
            duration: duration,
            transcript: transcript,
            sentAsText: true
        )
    }

    /// 删除本地语音文件（消息删除/发送取消时调用，幂等）。
    static func delete(_ attachment: VoiceMessageAttachment) {
        try? FileManager.default.removeItem(at: attachment.localFileURL)
    }

    /// 16kHz 16bit 单声道 WAV 编码（与 OpenClawSTTService.encodeWAV 同格式）。
    static func wavData(samples: [Float], sampleRate: Int = 16000) -> Data {
        var data = Data()
        data.append(Data("RIFF".utf8))
        var chunkSize = (36 + samples.count * 2).littleEndian
        data.append(Data(bytes: &chunkSize, count: MemoryLayout<Int32>.size))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        var subchunk1Size = Int32(16).littleEndian
        data.append(Data(bytes: &subchunk1Size, count: MemoryLayout<Int32>.size))
        var audioFormat = Int16(1).littleEndian
        data.append(Data(bytes: &audioFormat, count: MemoryLayout<Int16>.size))
        var numChannels = Int16(1).littleEndian
        data.append(Data(bytes: &numChannels, count: MemoryLayout<Int16>.size))
        var sampleRate32 = Int32(sampleRate).littleEndian
        data.append(Data(bytes: &sampleRate32, count: MemoryLayout<Int32>.size))
        var byteRate = Int32(sampleRate * 2).littleEndian
        data.append(Data(bytes: &byteRate, count: MemoryLayout<Int32>.size))
        var blockAlign = Int16(2).littleEndian
        data.append(Data(bytes: &blockAlign, count: MemoryLayout<Int16>.size))
        var bitsPerSample = Int16(16).littleEndian
        data.append(Data(bytes: &bitsPerSample, count: MemoryLayout<Int16>.size))
        data.append(Data("data".utf8))
        var dataSize = Int32(samples.count * 2).littleEndian
        data.append(Data(bytes: &dataSize, count: MemoryLayout<Int32>.size))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * Float(Int16.max)).littleEndian
            data.append(Data(bytes: &int16, count: MemoryLayout<Int16>.size))
        }
        return data
    }
}
