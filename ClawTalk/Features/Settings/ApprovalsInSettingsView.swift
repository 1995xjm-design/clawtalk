import SwiftUI
import UIKit
import UserNotifications

/// 执行审批入口页（对齐官方 Approvals 页）：状态卡 + 通知警示卡 + 待审批列表。
struct ApprovalsInSettingsView: View {
    var gatewayConnection: GatewayConnection
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Environment(\.openURL) private var openURL

    private var notificationIsOn: Bool {
        ExecApprovalNotificationGuidance.isNotificationAuthorizationAllowed(notificationStatus)
    }

    private var notificationsNeedAttention: Bool {
        !notificationIsOn
    }

    private var pendingDetail: String {
        if gatewayConnection.pendingApprovals.isEmpty {
            return "没有等待审批的网关命令。"
        }
        return "有 \(gatewayConnection.pendingApprovals.count) 条命令等待审批。"
    }

    private var statusValue: String {
        if notificationsNeedAttention {
            return "通知未开启"
        }
        return gatewayConnection.pendingApprovals.isEmpty ? "无待审批" : "\(gatewayConnection.pendingApprovals.count) 条待审批"
    }

    private var statusColor: Color {
        if notificationsNeedAttention {
            return .orange
        }
        return gatewayConnection.pendingApprovals.isEmpty ? .green : .orange
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title3)
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("执行审批")
                            .font(.subheadline.weight(.semibold))
                        Text(pendingDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(statusValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
            }

            if notificationsNeedAttention {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("通知未开启", systemImage: "bell.badge")
                            .font(.subheadline.weight(.semibold))
                        Text("开启通知后，App 不在前台时也能收到审批提醒。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: openSystemSettings) {
                            Label("打开通知设置", systemImage: "bell.badge")
                                .font(.subheadline)
                        }
                    }
                }
            }

            if !gatewayConnection.pendingApprovals.isEmpty {
                Section("待审批") {
                    ForEach(gatewayConnection.pendingApprovals) { approval in
                        ApprovalBannerView(approval: approval) { id, decision in
                            Task {
                                try? await gatewayConnection.resolveApproval(id: id, decision: decision)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("执行审批")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshNotificationStatus()
        }
        .onChange(of: gatewayConnection.pendingApprovals.count) { _, _ in
            Task {
                await refreshNotificationStatus()
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationStatus = settings.authorizationStatus
    }
}
