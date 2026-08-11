import SwiftUI
import UIKit
import Photos
import AVFoundation
import Contacts
import EventKit
import UserNotifications

/// 隐私与访问权限：展示各项权限授权状态，点击跳转系统设置。
struct PrivacyPermissionsView: View {
    @State private var photoStatus = ""
    @State private var cameraStatus = ""
    @State private var micStatus = ""
    @State private var contactsStatus = ""
    @State private var calendarStatus = ""
    @State private var remindersStatus = ""
    @State private var notificationStatus = ""

    var body: some View {
        List {
            Section {
                permissionRow("照片", icon: "photo", status: photoStatus)
                permissionRow("相机", icon: "camera", status: cameraStatus)
                permissionRow("麦克风", icon: "mic", status: micStatus)
                permissionRow("联系人", icon: "person.crop.circle", status: contactsStatus)
                permissionRow("日历", icon: "calendar", status: calendarStatus)
                permissionRow("提醒", icon: "bell", status: remindersStatus)
                permissionRow("通知", icon: "bell.badge", status: notificationStatus)
            } header: {
                Text("权限状态")
            } footer: {
                Text("点击任意一行可前往系统设置查看/调整该 App 的权限。权限被拒绝时，对应功能（如照片、麦克风）将不可用，请手动开启。")
            }

            Section {
                Button {
                    openSystemSettings()
                } label: {
                    Label("前往系统设置", systemImage: "gear")
                }
            }
        }
        .navigationTitle("隐私与访问权限")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .refreshable { refresh() }
    }

    private func permissionRow(_ title: String, icon: String, status: String) -> some View {
        Button {
            openSystemSettings()
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(status.isEmpty ? "—" : status)
                    .font(.caption)
                    .foregroundStyle(statusColor(status))
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "已授权", "部分访问", "仅写入", "临时授权":
            return .green
        case "未请求":
            return .secondary
        default:
            return .red
        }
    }

    private func refresh() {
        photoStatus = Self.photosStatusText()
        cameraStatus = Self.avStatusText(AVCaptureDevice.authorizationStatus(for: .video))
        micStatus = Self.micStatusText()
        contactsStatus = Self.contactsStatusText(CNContactStore.authorizationStatus(for: .contacts))
        calendarStatus = Self.eventStatusText(EKEventStore.authorizationStatus(for: .event))
        remindersStatus = Self.eventStatusText(EKEventStore.authorizationStatus(for: .reminder))
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text = Self.notificationStatusText(settings.authorizationStatus)
            Task { @MainActor in
                notificationStatus = text
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Status Helpers

    private static func photosStatusText() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return "已授权"
        case .limited: return "部分访问"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }

    private static func contactsStatusText(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .limited: return "部分访问"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }

    private static func avStatusText(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }

    private static func micStatusText() -> String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "已授权"
        case .denied: return "已拒绝"
        case .undetermined: return "未请求"
        default: return "未知"
        }
    }

    private static func eventStatusText(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "已授权"
        case .writeOnly: return "仅写入"
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }

    private static func notificationStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .provisional: return "临时授权"
        case .ephemeral: return "临时授权"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }
}