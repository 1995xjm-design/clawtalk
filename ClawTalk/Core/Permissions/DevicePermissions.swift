import AVFoundation
import Contacts
import EventKit
import Foundation
import Photos

/// 设备权限抽象（对齐官方 DevicePermissions）：统一枚举 + 状态快照。
enum DevicePermissionKind: String, CaseIterable, Identifiable, Sendable {
    case contacts
    case photos
    case eventKitRead
    case eventKitWrite
    case microphone
    case camera

    var id: String { rawValue }
}

enum DevicePermissionGrant: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case restricted
}

struct DevicePermissionStatusMap: Equatable, Sendable {
    var statuses: [DevicePermissionKind: DevicePermissionGrant]

    subscript(_ kind: DevicePermissionKind) -> DevicePermissionGrant {
        statuses[kind] ?? .notDetermined
    }
}

enum DevicePermissions {
    static func contacts() -> DevicePermissionGrant {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }

    static func photos() -> DevicePermissionGrant {
        switch PHPhotoLibrary.authorizationStatus() {
        case .authorized, .limited: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }

    static func eventKitRead() -> DevicePermissionGrant {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted, .writeOnly: return .restricted
        @unknown default: return .notDetermined
        }
    }

    static func eventKitWrite() -> DevicePermissionGrant {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess, .writeOnly: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }

    static func microphone() -> DevicePermissionGrant {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return DevicePermissionGrant.notDetermined
        @unknown default: return DevicePermissionGrant.notDetermined
        }
    }

    static func camera() -> DevicePermissionGrant {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }

    static func snapshot() -> DevicePermissionStatusMap {
        DevicePermissionStatusMap(statuses: [
            .contacts: contacts(),
            .photos: photos(),
            .eventKitRead: eventKitRead(),
            .eventKitWrite: eventKitWrite(),
            .microphone: microphone(),
            .camera: camera(),
        ])
    }
}
