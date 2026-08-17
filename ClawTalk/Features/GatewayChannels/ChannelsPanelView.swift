import SwiftUI

/// 网关频道管理面板：channels.status / channels.start / channels.stop / channels.logout。
/// 展示网关上报的频道与账号状态（configured/enabled/running/connected/linked/healthState）。
struct ChannelsPanelView: View {
    var gatewayConnection: GatewayConnection

    @State private var status: ChannelsStatusResponse?
    @State private var busy = false
    @State private var errorText: String?
    @State private var actionMessage: String?

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            if let actionMessage {
                Section {
                    Label(actionMessage, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }

            if let status {
                let order = status.channelOrder ?? []
                let channels = status.channels ?? []
                let accounts = status.channelAccounts ?? []

                if channels.isEmpty && accounts.isEmpty {
                    Section {
                        Text("网关未上报任何频道")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(order.isEmpty ? channels.map { $0.channel ?? "unknown" } : order, id: \.self) { channelID in
                    channelSection(channelID, channels: channels, accounts: accounts, labels: status.channelLabels ?? [:])
                }
            } else {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("正在读取频道状态…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("频道管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    if busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(busy)
            }
        }
        .task {
            await refresh()
        }
    }

    private func channelSection(_ channelID: String, channels: [ChannelEntry], accounts: [ChannelAccount], labels: [String: String]) -> some View {
        let channel = channels.first { $0.channel == channelID }
        let channelAccounts = accounts.filter { $0.channel == channelID }
        let title = labels[channelID] ?? channel?.label ?? channelID

        return Section(title) {
            if channelAccounts.isEmpty {
                Text("未配置账号")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(channelAccounts) { account in
                accountRow(account)
            }
        }
    }

    private func accountRow(_ account: ChannelAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(for: account))
                    .frame(width: 9, height: 9)
                Text(account.label ?? account.accountId ?? "账号")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let healthState = account.healthState, !healthState.isEmpty {
                    Text(healthState)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                statusTag("已配置", account.configured ?? false)
                statusTag("已启用", account.enabled ?? false)
                statusTag("运行中", account.running ?? false)
                statusTag("已连接", account.connected ?? false)
                statusTag("已关联", account.linked ?? false)
            }

            HStack(spacing: 16) {
                if account.running == true {
                    Button("停止") {
                        Task { await channelAction("channels.stop", account: account, message: "已请求停止") }
                    }
                    .font(.caption)
                    .disabled(busy)
                } else {
                    Button("启动") {
                        Task { await channelAction("channels.start", account: account, message: "已请求启动") }
                    }
                    .font(.caption)
                    .disabled(busy)
                }
                if account.configured == true {
                    Button("登出") {
                        Task { await channelAction("channels.logout", account: account, message: "已请求登出") }
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .disabled(busy)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statusTag(_ title: String, _ on: Bool) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(on ? Color.green.opacity(0.15) : Color.gray.opacity(0.12))
            }
            .foregroundStyle(on ? Color.green : Color.secondary)
    }

    private func statusColor(for account: ChannelAccount) -> Color {
        if account.connected == true || account.running == true { return .green }
        if account.healthState?.lowercased() == "error" || account.healthState?.lowercased() == "failed" { return .red }
        return .orange
    }

    // MARK: - RPC

    private func refresh() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let data = try await gatewayConnection.request(
                method: "channels.status",
                params: ["probe": AnyCodable(false), "timeoutMs": AnyCodable(10000)],
                timeoutMs: 20
            )
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            status = try decoder.decode(ChannelsStatusResponse.self, from: data)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func channelAction(_ method: String, account: ChannelAccount, message: String) async {
        busy = true
        errorText = nil
        actionMessage = nil
        defer { busy = false }
        do {
            var params: [String: AnyCodable] = [:]
            if let channel = account.channel { params["channel"] = AnyCodable(channel) }
            if let accountId = account.accountId { params["accountId"] = AnyCodable(accountId) }
            _ = try await gatewayConnection.request(method: method, params: params, timeoutMs: 20)
            actionMessage = message
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Models

struct ChannelsStatusResponse: Codable {
    var channelOrder: [String]?
    var channelLabels: [String: String]?
    var channels: [ChannelEntry]?
    var channelAccounts: [ChannelAccount]?
}

struct ChannelEntry: Codable, Identifiable {
    var id: String? { channel }
    var channel: String?
    var label: String?
    var enabled: Bool?
    var running: Bool?
}

struct ChannelAccount: Codable, Identifiable {
    var id: String? { accountId }
    var accountId: String?
    var channel: String?
    var label: String?
    var configured: Bool?
    var enabled: Bool?
    var running: Bool?
    var connected: Bool?
    var linked: Bool?
    var healthState: String?
}