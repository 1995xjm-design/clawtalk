import SwiftUI

struct ChannelListView: View {
    @Bindable var channelStore: ChannelStore
    var settingsStore: SettingsStore
    var gatewayConnection: GatewayConnection
    var onSelect: (Channel) -> Void

    @State private var showAddChannel = false
    @State private var showSettings = false
    @State private var showTools = false
    @State private var editingChannel: Channel?

    var body: some View {
        NavigationStack {
            List {
                ForEach(channelStore.channels) { channel in
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
                            Label("编辑频道", systemImage: "pencil")
                        }
                        Button(role: .destructive, action: { channelStore.delete(channel) }) {
                            Label("删除频道", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    for idx in indexSet {
                        channelStore.delete(channelStore.channels[idx])
                    }
                }
                .onMove { source, destination in
                    channelStore.move(from: source, to: destination)
                }

                Section {
                    Button(action: { showAddChannel = true }) {
                        HStack {
                            Spacer()
                            Image(systemName: "plus")
                                .font(.body)
                                .fontWeight(.semibold)
                            Text("新建频道")
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
                if channelStore.channels.isEmpty {
                    VStack(spacing: 16) {
                        Image("LogoRed")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .opacity(0.6)
                        Text("还没有频道")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
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
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showTools = true }) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.openClawRed)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: settingsStore, gatewayConnection: gatewayConnection)
            }
            .sheet(isPresented: $showAddChannel) {
                AddChannelView(channelStore: channelStore, settings: settingsStore)
            }
            .sheet(isPresented: $showTools) {
                ToolsView(settings: settingsStore, gatewayConnection: gatewayConnection)
            }
            .sheet(item: $editingChannel) { channel in
                EditChannelView(channelStore: channelStore, channel: channel)
            }
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
