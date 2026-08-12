import SwiftUI
import UIKit
import Photos
import AVFoundation
import Contacts
import EventKit
import UserNotifications

/// 隐私与访问权限：展示各项权限授权状态。
/// - 未请求：点击胶囊开关原地弹出系统授权框；
/// - 已拒绝/受限：点击胶囊开关跳转系统设置（底部「前往系统设置」按钮同样保留）；
/// - 已授权：胶囊显示开启状态，点击无操作。
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
                permissionRow("照片", icon: "photo", status: photoStatus, kind: .photos)
                permissionRow("相机", icon: "camera", status: cameraStatus, kind: .camera)
                permissionRow("麦克风", icon: "mic", status: micStatus, kind: .microphone)
                permissionRow("联系人", icon: "person.crop.circle", status: contactsStatus, kind: .contacts)
                permissionRow("日历", icon: "calendar", status: calendarStatus, kind: .calendar)
                permissionRow("提醒", icon: "bell", status: remindersStatus, kind: .reminders)
                permissionRow("通知", icon: "bell.badge", status: notificationStatus, kind: .notifications)
            } header: {
                Text("权限状态")
            } footer: {
                Text("未请求的权限可直接点击右侧开关原地授权；已拒绝的权限需前往系统设置开启。权限被拒绝时，对应功能（如照片、麦克风）将不可用。")
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

    /// 权限类型：与系统授权 API 一一对应。
    private enum PermissionKind {
        case photos, camera, microphone, contacts, calendar, reminders, notifications
    }

    private func permissionRow(_ title: String, icon: String, status: String, kind: PermissionKind) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(status.isEmpty ? "—" : status)
                .font(.caption)
                .foregroundStyle(statusColor(status))
            CapsulePermissionControl(status: status) {
                handleTap(status: status, kind: kind)
            }
        }
    }

    /// 点击胶囊开关：未请求→原地请求授权；已拒绝/受限→跳系统设置；已授权→无操作。
    private func handleTap(status: String, kind: PermissionKind) {
        switch status {
        case "未请求":
            request(kind)
        case "已拒绝", "受限", "未知":
            openSystemSettings()
        default:
            break
        }
    }

    private func request(_ kind: PermissionKind) {
        switch kind {
        case .photos:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                Task { @MainActor in refresh() }
            }
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                Task { @MainActor in refresh() }
            }
        case .microphone:
            AVAudioApplication.requestRecordPermission { _ in
                Task { @MainActor in refresh() }
            }
        case .contacts:
            CNContactStore().requestAccess(for: .contacts) { _, _ in
                Task { @MainActor in refresh() }
            }
        case .calendar:
            EKEventStore().requestFullAccessToEvents { _, _ in
                Task { @MainActor in refresh() }
            }
        case .reminders:
            EKEventStore().requestFullAccessToReminders { _, _ in
                Task { @MainActor in refresh() }
            }
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                Task { @MainActor in refresh() }
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

/// 胶囊形权限开关：按当前权限状态渲染（未请求=授权；已拒绝=前往设置；已授权=已开启）。
private struct CapsulePermissionControl: View {
    let status: String
    let action: () -> Void

    private var isGranted: Bool {
        ["已授权", "部分访问", "仅写入", "临时授权"].contains(status)
    }

    private var isDenied: Bool {
        ["已拒绝", "受限", "未知"].contains(status)
    }

    private var fillColor: Color {
        if isGranted { return .green }
        if isDenied { return .red }
        return .orange
    }

    private var labelText: String {
        if isGranted { return "已开启" }
        if isDenied { return "前往设置" }
        return "授权"
    }

    var body: some View {
        Button(action: action) {
            Text(labelText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(fillColor))
        }
        .buttonStyle(.plain)
        .disabled(isGranted)
    }
}
