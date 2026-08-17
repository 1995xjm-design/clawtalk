import AVFoundation
import Foundation

/// Talk 模式权限扩展（对齐官方 TalkModeManager+Permissions）：
/// 麦克风权限请求与状态、音频会话配置。
extension TalkModeManager {
    enum MicrophonePermissionState: Equatable {
        case undetermined
        case granted
        case denied
        case restricted
    }

    /// 当前麦克风权限状态。
    static var microphonePermissionState: MicrophonePermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return MicrophonePermissionState.restricted
        }
    }

    /// 请求麦克风权限（异步），返回是否可用。
    static func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied, .restricted: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    /// 配置音频会话（扬声器偏好，对齐 TalkDefaults / TalkAudioRoute）。
    static func configureAudioSession() {
        let speakerphone = TalkDefaults.speakerphoneEnabled()
        let options = TalkAudioRoute.categoryOptions(speakerphoneEnabled: speakerphone)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try? session.setActive(true)
    }
}
