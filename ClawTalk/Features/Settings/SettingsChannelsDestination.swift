import SwiftUI

/// 频道设置（对齐官方 SettingsChannelsDestination 精简）：
/// 展示各频道接入状态并提供启停/退出操作（channels.status/start/stop/logout）。
struct SettingsChannelsDestination: View {
    var gatewayConnection: GatewayConnection

    @State private var channels: [ChannelStatusItem] = []
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section("频道") {
                if channels.isEmpty && !busy {
                    Text("无频道或网关未支持 channels.*")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(channels) { channel in
                    channelRow(channel)
                }
            }
        }
        .navigationTitle("频道设置")
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
        .task { await refresh() }
    }

    /// 单行频道（拆出子视图，避免 List 大表达式类型检查超时）。
    private func channelRow(_ channel: ChannelStatusItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: channel.kind))
                .foregroundStyle(channel.enabled == true ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name.flatMap { $0.isEmpty ? nil : $0 } ?? channel.kind)
                    .font(.subheadline.weight(.medium))
                if let account = channel.account, !account.isEmpty {
                    Text(account)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if busy {
                ProgressView()
            } else {
                Menu {
                    Button {
                        Task { await toggle(channel) }
                    } label: {
                        Label(channel.enabled == true ? "停止" : "启动", systemImage: channel.enabled == true ? "stop.circle" : "play.circle")
                    }
                    Button {
                        Task { await logout(channel) }
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            }
        }
    }

    private func icon(for kind: String) -> String {
        switch kind.lowercased() {
        case "wechat", "wx": return "message.fill"
        case "telegram", "tg": return "paperplane.fill"
        case "slack": return "number"
        case "whatsapp", "wa": return "phone.fill"
        default: return "rectangle.3.group"
        }
    }

    private func refresh() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let data = try await gatewayConnection.request(method: "channels.status", params: nil, timeoutMs: 12)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            channels = (try? decoder.decode(ChannelStatusResponse.self, from: data))?.channels ?? []
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func toggle(_ channel: ChannelStatusItem) async {
        busy = true
        defer { busy = false }
        let method = channel.enabled == true ? "channels.stop" : "channels.start"
        do {
            _ = try await gatewayConnection.request(
                method: method,
                params: ["kind": AnyCodable(channel.kind)],
                timeoutMs: 15)
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func logout(_ channel: ChannelStatusItem) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await gatewayConnection.request(
                method: "channels.logout",
                params: ["kind": AnyCodable(channel.kind)],
                timeoutMs: 15)
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct ChannelStatusItem: Codable, Identifiable {
    var id: String { kind }
    var kind: String
    var name: String?
    var enabled: Bool?
    var account: String?
    var status: String?
}

private struct ChannelStatusResponse: Codable {
    var channels: [ChannelStatusItem]?
    var ok: Bool?
}
