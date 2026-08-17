import EventKit
import Foundation

/// EventKit 权限请求（对齐官方 EventKitPermissionRequester）：
/// 日历/提醒写入与完整访问请求。
enum EventKitPermissionRequester {
    @MainActor
    static func requestWriteOnlyAccessToEvents() async -> Bool {
        await withCheckedContinuation { continuation in
            let store = EKEventStore()
            store.requestWriteOnlyAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    @MainActor
    static func requestFullAccessToEvents() async -> Bool {
        await withCheckedContinuation { continuation in
            let store = EKEventStore()
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    @MainActor
    static func requestFullAccessToReminders() async -> Bool {
        await withCheckedContinuation { continuation in
            let store = EKEventStore()
            store.requestFullAccessToReminders { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}

/// EventKit 授权状态（对齐官方 EventKitAuthorization）。
enum EventKitAuthorization {
    static func allowsRead() -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess: return true
        case .denied, .notDetermined, .restricted, .writeOnly: return false
        @unknown default: return false
        }
    }

    static func allowsWrite() -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess, .writeOnly: return true
        case .denied, .notDetermined, .restricted: return false
        @unknown default: return false
        }
    }
}
