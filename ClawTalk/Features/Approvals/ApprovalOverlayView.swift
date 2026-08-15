import SwiftUI

/// Overlay that shows pending exec approval dialogs.
/// Placed as an overlay on the root app view: dims the app and presents a
/// centered confirmation card when a command-execution approval is pending.
struct ApprovalOverlayView: View {
    var gatewayConnection: GatewayConnection

    var body: some View {
        let approvals = gatewayConnection.pendingApprovals
        ZStack {
            if !approvals.isEmpty {
                // Dim + disable the app underneath while an approval is pending.
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)
                    .onTapGesture {
                        // 点击遮罩不取消（命令审批需要显式决策，避免误触放行）
                    }
                    .transition(.opacity)

                VStack(spacing: 10) {
                    ForEach(approvals) { approval in
                        ApprovalBannerView(approval: approval) { id, decision in
                            Task {
                                try? await gatewayConnection.resolveApproval(id: id, decision: decision)
                            }
                        }
                        .transition(.scale(scale: 0.98).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 460)
                .transition(.scale(scale: 0.98).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: approvals.map(\.id))
        // 周期清理已过期审批（此前从未调用，过期审批会一直挂着）
        .task(id: approvals.map(\.id)) {
            while !Task.isCancelled {
                gatewayConnection.pruneExpiredApprovals()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
