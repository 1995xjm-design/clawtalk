import Foundation

/// 语音输入 STT 工厂与切分工具（主 App 统一规则）：
/// 与 ClawTalkApp.configureServices 同规则：.apple → AppleSTTService(language: whisperLanguage)；
/// .doubao → 有豆包 API Key 用 DoubaoSTTService，否则回退 Apple；voiceInputEnabled 关闭 → nil。
enum VoiceInputSTTFactory {
    static func make(settingsStore: SettingsStore) -> (any TranscriptionService)? {
        let settings = settingsStore.settings
        guard settings.voiceInputEnabled else { return nil }

        let service: any TranscriptionService
        switch settings.sttProvider {
        case .apple:
            service = AppleSTTService(language: settings.whisperLanguage)
        case .doubao:
            if let key = SecureStorage.shared.doubaoAPIKey, !key.isEmpty {
                service = DoubaoSTTService(apiKey: key, language: settings.whisperLanguage)
            } else {
                service = AppleSTTService(language: settings.whisperLanguage)
            }
        }
        return service
    }

    /// 长录音按 50 秒一段切分（16kHz 单声道），逐段转写后拼接，控制单次识别长度。
    static func chunk(_ samples: [Float]) -> [[Float]] {
        let chunkSize = 16000 * 50
        guard samples.count > chunkSize else { return [samples] }
        var result: [[Float]] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            result.append(Array(samples[offset..<end]))
            offset = end
        }
        return result
    }
}
