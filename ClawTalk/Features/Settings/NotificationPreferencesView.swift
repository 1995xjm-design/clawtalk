import SwiftUI
import UIKit
import UserNotifications

// MARK: - 通知分类

/// 通知细分分类：每类一个开关（本地 UserDefaults 独立键，不改 AppSettings Codable 结构）。
enum NotificationCategory: String, CaseIterable, Identifiable {
    case messageReply = "消息回复"
    case taskComplete = "任务完成"
    case reminder = "提醒"
    case healthAlert = "健康告警"
    case automationResult = "自动化结果"
    case system = "系统"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .messageReply: return "bubble.left.and.bubble.right"
        case .taskComplete: return "checkmark.circle"
        case .reminder: return "bell"
        case .healthAlert: return "heart.circle"
        case .automationResult: return "gearshape.2"
        case .system: return "gearshape"
        }
    }

    var detail: String {
        switch self {
        case .messageReply: return "智能体回复新消息时通知"
        case .taskComplete: return "后台任务完成时通知"
        case .reminder: return "居家健康提醒到点通知"
        case .healthAlert: return "连接异常 / 健康状态告警通知"
        case .automationResult: return "自动化任务结果通知"
        case .system: return "配对、升级、系统消息通知"
        }
    }

    fileprivate var defaultsKey: String { "clawtalk_notif_\(rawValue)" }
}

// MARK: - 通知分类开关存储

enum NotificationPreferences {

    /// 分类是否开启（未写入过时默认开启）。
    static func isEnabled(_ category: NotificationCategory) -> Bool {
        UserDefaults.standard.object(forKey: category.defaultsKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, for category: NotificationCategory) {
        UserDefaults.standard.set(enabled, forKey: category.defaultsKey)
    }

    /// 是否仍有任意分类开启（展示用）。
    static var hasAnyEnabled: Bool {
        NotificationCategory.allCases.contains { isEnabled($0) }
    }
}

// MARK: - 通知细分管理页

/// 分类管理通知开关：消息回复 / 任务完成 / 提醒 / 健康告警 / 自动化结果 / 系统。
struct NotificationPreferencesView: View {
    @State private var systemStatus: UNAuthorizationStatus = .notDetermined
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                ForEach(NotificationCategory.allCases) { category in
                    Toggle(isOn: Binding(
                        get: { NotificationPreferences.isEnabled(category) },
                        set: { NotificationPreferences.setEnabled($0, for: category) }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.rawValue)
                                Text(category.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: category.systemImage)
                                .foregroundStyle(Color.openClawRed)
                        }
                    }
                }
            } header: {
                Text("分类开关")
            } footer: {
                Text("关闭某类后，ClawTalk 将不再发送该类通知。此处仅控制 ClawTalk 自身通知，系统级通知权限仍需在系统设置中开启。")
            }

            Section {
                LabeledContent("系统通知权限", value: systemStatusText)
                if systemStatus == .denied || systemStatus == .notDetermined {
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
            } header: {
                Text("系统状态")
            } footer: {
                Text(systemStatusFooter)
            }
        }
        .navigationTitle("通知管理")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshSystemStatus()
        }
    }

    private var systemStatusText: String {
        switch systemStatus {
        case .authorized, .ephemeral, .provisional:
            return "已开启"
        case .denied:
            return "已关闭"
        case .notDetermined:
            return "未请求"
        @unknown default:
            return "未知"
        }
    }

    private var systemStatusFooter: String {
        switch systemStatus {
        case .denied:
            return "系统通知权限已关闭，任何分类开关都不会生效。请在系统设置中重新开启。"
        case .notDetermined:
            return "打开任意分类后，ClawTalk 首次发送通知时会请求系统权限。"
        default:
            return ""
        }
    }

    @MainActor
    private func refreshSystemStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        systemStatus = settings.authorizationStatus
    }
}
