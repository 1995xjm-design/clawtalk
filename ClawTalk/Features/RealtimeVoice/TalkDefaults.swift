import AVFoundation
import Foundation

/// Talk 语音默认参数（对齐官方 TalkDefaults）：静音超时 + 扬声器偏好。
enum TalkDefaults {
    static let silenceTimeoutMs = 900
    static let speakerphoneEnabledKey = "talk.speakerphone.enabled"
    static let speakerphoneEnabledByDefault = true

    static func speakerphoneEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: self.speakerphoneEnabledKey) != nil else {
            return self.speakerphoneEnabledByDefault
        }
        return defaults.bool(forKey: self.speakerphoneEnabledKey)
    }

    static func setSpeakerphoneEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: self.speakerphoneEnabledKey)
    }
}

/// 音频路由（对齐官方 TalkAudioRoute）：扬声器/蓝牙/听筒策略。
enum TalkAudioRoute {
    static func categoryOptions(speakerphoneEnabled: Bool) -> AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
        if speakerphoneEnabled {
            options.insert(.defaultToSpeaker)
        }
        return options
    }

    static func shouldForceSpeaker(
        preferenceEnabled: Bool,
        outputPortTypes: [AVAudioSession.Port]) -> Bool
    {
        guard preferenceEnabled else { return false }
        guard !outputPortTypes.isEmpty else { return false }
        return outputPortTypes.allSatisfy { $0 == .builtInReceiver || $0 == .builtInSpeaker }
    }
}
