import SwiftUI

/// 手表端主界面：连接状态 + 频道选择 + 消息列表 + 语音/唤醒/刷新。
/// 所有数据都来自真实来源（App Group 频道列表 + WatchConnectivity 消息），
/// 拿不到数据时显示诚实空状态，不伪造内容。
struct MessageListView: View {
    @EnvironmentObject private var session: WatchSessionManager
    @StateObject private var channelStore = WatchChannelStore()
    @State private var selectedChannel: WatchChannel?

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                channelSection
                messageSection
            }
            .navigationTitle("ClawTalk")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    HStack(spacing: 8) {
                        VoiceInputButton { text in
                            session.sendText(text, channelName: selectedChannel?.name)
                        }
                        Button {
                            session.wakeAgent(channelName: selectedChannel?.name)
                        } label: {
                            Label("唤醒", systemImage: "bolt.fill")
                        }
                        Button {
                            refresh()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .task {
                session.activate()
                channelStore.refresh()
                session.requestChannels()
                session.requestMessages(channelName: selectedChannel?.name)
            }
            .onChange(of: session.channels) { _, channels in
                if selectedChannel == nil, let first = channels.first {
                    selectedChannel = first
                    session.requestMessages(channelName: first.name)
                }
            }
        }
    }

    // MARK: - 连接状态

    private var connectionSection: some View {
        Section {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.isReachable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(session.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 频道

    private var channelSection: some View {
        Section("频道") {
            if channelStore.channels.isEmpty {
                Text("还没有频道。请在 iPhone 的 ClawTalk 里配置网关并添加频道，列表会自动同步。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(channelStore.channels) { channel in
                    Button {
                        selectedChannel = channel
                        session.requestMessages(channelName: channel.name)
                    } label: {
                        HStack {
                            Text(channel.name)
                            Spacer()
                            if selectedChannel?.id == channel.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 消息

    private var messageSection: some View {
        Section("消息") {
            if session.messages.isEmpty {
                Text("暂无消息。连上 iPhone 后点「刷新」，或用下方「语音」发一条试试。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.messages) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.content)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
                        Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 刷新

    private func refresh() {
        channelStore.refresh()
        session.requestChannels()
        session.requestMessages(channelName: selectedChannel?.name)
    }
}