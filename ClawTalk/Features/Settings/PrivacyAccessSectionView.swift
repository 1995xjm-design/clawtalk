import AVFoundation
import Contacts
import CoreLocation
import EventKit
import HealthKit
import Photos
import SwiftUI

/// 隐私访问区（对齐官方 PrivacyAccessSectionView）：
/// 汇总隐私权限快照（定位/健康/日历/通讯录/照片/麦克风），点按直达系统设置。
struct PrivacyGatewayPermissionSnapshot: Equatable {
    var location: String?
    var health: String?
    var calendar: String?
    var contacts: String?
    var photos: String?
    var microphone: String?
}

struct PrivacyAccessSectionView: View {
    var snapshot: PrivacyGatewayPermissionSnapshot = PrivacyAccessSectionView.currentSnapshot()

    var body: some View {
        List {
            Section("隐私访问") {
                row("定位", snapshot.location, "location.fill")
                row("健康", snapshot.health, "heart.fill")
                row("日历", snapshot.calendar, "calendar")
                row("通讯录", snapshot.contacts, "person.crop.circle")
                row("照片", snapshot.photos, "photo.fill")
                row("麦克风", snapshot.microphone, "mic.fill")
            }
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打开系统设置", systemImage: "gear")
                }
            } footer: {
                Text("权限在系统设置中管理；本应用读取权限用于对应功能卡。")
            }
        }
        .navigationTitle("隐私访问")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String?, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value ?? "未知")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func currentSnapshot() -> PrivacyGatewayPermissionSnapshot {
        PrivacyGatewayPermissionSnapshot(
            location: statusLabel(CLLocationManager().authorizationStatus),
            health: HKHealthStore.isHealthDataAvailable() ? "可用" : "不可用",
            calendar: EKEventStore.authorizationStatus(for: .event).statusLabel(),
            contacts: CNContactStore.authorizationStatus(for: .contacts).statusLabel(),
            photos: PHPhotoLibrary.authorizationStatus().statusLabel(),
            microphone: microphoneStatusLabel())
    }

    private static func statusLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未决定"
        case .restricted: return "受限"
        @unknown default: return "未知"
        }
    }
}


    private static func microphoneStatusLabel() -> String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "已授权"
        case .denied: return "已拒绝"
        case .undetermined: return "未决定"
        @unknown default: return "未知"
        }
    }
}

private extension CLAuthorizationStatus {
    var statusLabel: String { PrivacyAccessSectionView.statusLabel(self) }
}

private extension EKAuthorizationStatus {
    var statusLabel: String {
        switch self {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未决定"
        case .restricted: return "受限"
        @unknown default: return "未知"
        }
    }
}

private extension CNAuthorizationStatus {
    var statusLabel: String {
        switch self {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未决定"
        case .restricted: return "受限"
        @unknown default: return "未知"
        }
    }
}

private extension PHAuthorizationStatus {
    var statusLabel: String {
        switch self {
        case .authorized, .limited: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未决定"
        case .restricted: return "受限"
        @unknown default: return "未知"
        }
    }
}
