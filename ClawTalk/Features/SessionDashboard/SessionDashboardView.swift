import SwiftUI

/// 会话仪表盘（SessionDashboardScreen 精简版）：当前会话信息 + 网关状态 + 快捷操作。
struct SessionDashboardView: View {
    var gatewayConnection: GatewayConnection
    var settingsStore: SettingsStore

    var body: some View {
        List {
            Section("网关状态") {
                HStack {
                    Text("连接状态")
                    Spacer()
                    switch gatewayConnection.connectionState {
                    case .connected:
                        Label("已连接", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .connecting:
                        Label("连接中", systemImage: "ellipsis.circle")
                            .foregroundStyle(.orange)
                    case .disconnected:
                        Label("未连接", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    Text("网关地址")
                    Spacer()
                    Text(settingsStore.settings.gatewayURL.isEmpty ? "未配置" : settingsStore.settings.gatewayURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let lastError = gatewayConnection.lastError {
                    HStack(alignment: .top) {
                        Text("最近错误")
                        Spacer()
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Section("快捷操作") {
                Button {
                    Task { await reconnect() }
                } label: {
                    Label("重新连接", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await disconnect() }
                } label: {
                    Label("断开连接", systemImage: "xmark.circle")
                }
            }
        }
        .navigationTitle("会话仪表盘")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reconnect() async {
        let url = settingsStore.settings.resolvedWebSocketURL
        guard !url.isEmpty else { return }
        await gatewayConnection.disconnect()
        await gatewayConnection.connect(resolvedURL: url, token: settingsStore.gatewayToken)
    }

    private func disconnect() async {
        await gatewayConnection.disconnect()
    }
}