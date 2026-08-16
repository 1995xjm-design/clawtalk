import SwiftUI
import UIKit
import UserNotifications

// MARK: - 审批通知引导（对齐官方 NotificationPermissionGuidanceDialog）

/// 审批到达但系统通知未授权时的引导提示模型。
struct NotificationGuidancePrompt: Identifiable, Equatable {
    let id: UUID

    init() {
        id = UUID()
    }
}

/// 引导持久化与系统通知状态判断。
enum ExecApprovalNotificationGuidance {
    static let suppressKey = "clawtalk_exec_approval_notification_guidance_suppressed"

    static var isSuppressed: Bool {
        UserDefaults.standard.bool(forKey: suppressKey)
    }

    static func suppressFuture() {
        UserDefaults.standard.set(true, forKey: suppressKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: suppressKey)
    }

    /// 系统通知是否可用（对齐官方：authorized/provisional/ephemeral 视为可用）。
    static func isNotificationAuthorizationAllowed(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }
}

/// 审批到达且通知未开启时的全局引导卡片（对齐官方：打开通知设置 / 稍后 / 不再显示）。
private struct NotificationGuidanceCard: View {
    let onOpenNotifications: () -> Void
    let onDismiss: () -> Void
    let onSuppressFuture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("通知未开启", systemImage: "bell.badge")
                    .font(.headline)
                Text(
                    "命令执行审批只能在 App 打开且连接时进行。\n\n开启通知后，App 不在前台时也能收到审批提醒。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button(action: onOpenNotifications) {
                    Text("打开通知设置")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .cancel, action: onDismiss) {
                    Text("稍后")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onSuppressFuture) {
                    Text("不再显示")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        )
    }
}

private struct NotificationGuidanceDialogModifier: ViewModifier {
    let guidance: NotificationGuidancePrompt?
    let onDismiss: (Bool) -> Void
    let onOpenNotifications: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if let prompt = guidance {
                    ZStack {
                        Color.black.opacity(0.38)
                            .ignoresSafeArea()
                            .allowsHitTesting(true)

                        NotificationGuidanceCard(
                            onOpenNotifications: {
                                onDismiss(false)
                                onOpenNotifications()
                            },
                            onDismiss: {
                                onDismiss(false)
                            },
                            onSuppressFuture: {
                                onDismiss(true)
                            })
                            .padding(.horizontal, 20)
                            .frame(maxWidth: 460)
                            .transition(.scale(scale: 0.98).combined(with: .opacity))
                    }
                    .zIndex(2)
                    .id(prompt.id)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: guidance?.id)
    }
}

extension View {
    /// 审批通知引导弹窗（对齐官方 notificationPermissionGuidanceDialog）。
    func notificationGuidanceDialog(
        guidance: NotificationGuidancePrompt?,
        onDismiss: @escaping (Bool) -> Void,
        onOpenNotifications: @escaping () -> Void) -> some View
    {
        modifier(NotificationGuidanceDialogModifier(
            guidance: guidance,
            onDismiss: onDismiss,
            onOpenNotifications: onOpenNotifications))
    }
}
