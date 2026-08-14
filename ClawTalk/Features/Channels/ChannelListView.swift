import SwiftUI

struct ChannelListView: View {
    @Bindable var channelStore: ChannelStore
    var settingsStore: SettingsStore
    var gatewayConnection: GatewayConnection
    var nodeConnection: NodeConnection?
    var onSelect: (Channel) -> Void
    var onSelectFileTransfer: (() -> Void)?
    /// 网关会话入口：点开全部会话列表（复用 SessionsView），选会话后进入聊天
    var onOpenGatewaySessions: (() -> Void)?

    @State private var showAddChannel = false
    @State private var showSettings = false
    @State private var showTools = false
    @State private var editingChannel: Channel?

    /// 可见频道：隐藏自动创建的「文件传输」聊天频道（文件页由系统频道入口展示，避免重复入口）。
    private var visibleChannels: [Channel] {
        channelStore.channels.filter { $0.serverSessionKey != InstructionChannels.fileTransfer }
    }

    private var hiddenChannels: [Channel] {
        channelStore.channels.filter { $0.serverSessionKey == InstructionChannels.fileTransfer }
    }

    var body: some View {
            VStack(spacing: 0) {
                AgentStatusIndicator(gatewayConnection: gatewayConnection, settings: settingsStore)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 2)

                List {
                    Section {
                        Button(action: { onSelectFileTransfer?() }) {
                            HStack(spacing: 12) {
                                Image(systemName: "tray.and.arrow.down")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.openClawRed)
                                    .frame(width: 40, height: 40)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(localized: "File Transfer"))
                                        .font(.body)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                    Text(String(localized: "Send and receive files from your computer"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(action: { onOpenGatewaySessions?() }) {
                            HStack(spacing: 12) {
                                Image(systemName: "globe.americas")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.openClawRed)
                                    .frame(width: 40, height: 40)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(localized: "Gateway Sessions"))
                                        .font(.body)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                    Text(String(localized: "All sessions on your computer · tap to continue"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } header: {
                        Text(String(localized: "System Channels"))
                    }

                    ForEach(visibleChannels) { channel in
                        Button(action: { onSelect(channel) }) {
                            HStack(spacing: 12) {
                                Text(channel.name.prefix(1).uppercased())
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.openClawRed)
                                    .frame(width: 40, height: 40)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(channel.name)
                                        .font(.body)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                    Text("openclaw:\(channel.agentId)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(action: { editingChannel = channel }) {
                                Label(String(localized: "Edit Channel"), systemImage: "pencil")
                            }
                            Button(role: .destructive, action: { channelStore.delete(channel) }) {
                                Label(String(localized: "Delete Channel"), systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for idx in indexSet {
                            channelStore.delete(visibleChannels[idx])
                        }
                    }
                    .onMove { source, destination in
                        if hiddenChannels.isEmpty {
                            channelStore.move(from: source, to: destination)
                        } else {
                            var reordered = visibleChannels
                            reordered.move(fromOffsets: source, toOffset: destination)
                            channelStore.replace(reordered + hiddenChannels)
                        }
                    }

                    Section {
                        Button(action: { showAddChannel = true }) {
                            HStack {
                                Spacer()
                                Image(systemName: "plus")
                                    .font(.body)
                                    .fontWeight(.semibold)
                                Text(String(localized: "New Channel"))
                                    .font(.body)
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            .foregroundStyle(.white)
                            .padding(.vertical, 16)
                            .background(Color.openClawRed)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listSectionSpacing(.compact)
                }
                .overlay {
                    if visibleChannels.isEmpty {
                        VStack(spacing: 16) {
                            Image("LogoRed")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 80, height: 80)
                                .opacity(0.6)
                            Text(String(localized: "No channels yet"))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .background {
                if settingsStore.settings.globalGlassEnabled {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image("LogoRed")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 24)
                        Text("ClawTalk")
                            .font(.headline)
                            .fontWeight(.semibold)

                        if settingsStore.settings.useWebSocket {
                            Circle()
                                .fill(connectionDotColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.openClawRed)
                    }
                    .accessibilityLabel("打开设置")

                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showTools = true }) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.openClawRed)
                    }
                    .accessibilityLabel("打开工具")

                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: settingsStore, gatewayConnection: gatewayConnection, nodeConnection: nodeConnection)
            }
            .sheet(isPresented: $showAddChannel) {
                AddChannelView(channelStore: channelStore, settings: settingsStore)
            }
            .sheet(isPresented: $showTools) {
                ToolsView(settings: settingsStore, gatewayConnection: gatewayConnection, nodeConnection: nodeConnection)
            }
            .sheet(item: $editingChannel) { channel in
                EditChannelView(channelStore: channelStore, channel: channel)
            }
    }

    private var connectionDotColor: Color {
        switch gatewayConnection.connectionState {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .red
        }
    }
}
