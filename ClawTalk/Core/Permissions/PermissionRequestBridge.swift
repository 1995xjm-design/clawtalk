import AVFoundation
import Contacts
import EventKit
import Foundation
import Photos

/// 权限请求桥（对齐官方 PermissionRequestBridge）：
/// 集中处理一次性权限请求，等待结果后返回授权状态。
enum PermissionRequestBridge {
    static func request(_ kind: DevicePermissionKind) async -> DevicePermissionGrant {
        switch kind {
        case .contacts:
            return await withCheckedContinuation { continuation in
                CNContactStore().requestAccess(for: .contacts) { granted, _ in
                    continuation.resume(returning: granted ? .granted : .denied)
                }
            }
        case .photos:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization { status in
                    switch status {
                    case .authorized, .limited: continuation.resume(returning: .granted)
                    case .denied: continuation.resume(returning: .denied)
                    case .notDetermined: continuation.resume(returning: .notDetermined)
                    case .restricted: continuation.resume(returning: .restricted)
                    @unknown default: continuation.resume(returning: .notDetermined)
                    }
                }
            }
        case .eventKitRead, .eventKitWrite:
            return await withCheckedContinuation { continuation in
                let store = EKEventStore()
                store.requestWriteOnlyAccessToEvents { granted, _ in
                    continuation.resume(returning: granted ? .granted : .denied)
                }
            }
        case .microphone:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted ? .granted : .denied)
                }
            }
        case .camera:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted ? .granted : .denied)
                }
            }
        }
    }

    static func canStartRequest(_ kind: DevicePermissionKind) -> Bool {
        DevicePermissions.snapshot()[kind] == .notDetermined
    }
}
