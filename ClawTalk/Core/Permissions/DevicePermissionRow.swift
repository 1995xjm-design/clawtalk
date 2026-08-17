import SwiftUI
import UIKit

/// 设备权限行（对齐官方 DevicePermissionRow）：图标 + 名称 + 状态 + 请求/打开设置。
struct DevicePermissionRow: View {
    let kind: DevicePermissionKind
    var grant: DevicePermissionGrant
    var onRequest: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.body)
                .foregroundStyle(tintColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if grant == .notDetermined {
                Button("请求") {
                    onRequest?()
                }
                .buttonStyle(.bordered)
                .font(.caption)
            } else if grant == .denied || grant == .restricted {
                Button("设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        switch kind {
        case .contacts: return "通讯录"
        case .photos: return "照片"
        case .eventKitRead: return "日历读取"
        case .eventKitWrite: return "日历写入"
        case .microphone: return "麦克风"
        case .camera: return "摄像头"
        }
    }

    private var iconName: String {
        switch kind {
        case .contacts: return "person.crop.circle"
        case .photos: return "photo.fill"
        case .eventKitRead, .eventKitWrite: return "calendar"
        case .microphone: return "mic.fill"
        case .camera: return "camera.fill"
        }
    }

    private var statusText: String {
        switch grant {
        case .granted: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未决定"
        case .restricted: return "受限"
        }
    }

    private var tintColor: Color {
        switch grant {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        case .restricted: return .secondary
        }
    }
}
