import SwiftUI

struct SessionsView: View {
    @Bindable var viewModel: ToolsViewModel
    @State private var selectedSession: SessionEntry?
    @State private var showAddedAlert = false
    @State private var addedChannelName = ""

    var body: some View {
        List {
            if viewModel.sessions.isEmpty && !viewModel.isLoading {
                if let errorMessage = viewModel.errorMessage {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } actions: {
                        Button("重试") {
                            Task {
                                await viewModel.listSessions()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView(
                        "暂无会话",
                        systemImage: "list.bullet.rectangle",
                        description: Text("未找到活跃会话。\n下拉刷新试试")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            ForEach(viewModel.sessions) { session in
                NavigationLink {
                    SessionDetailView(viewModel: viewModel, session: session)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(viewModel.sessionTitles[session.key] ?? "会话 \(session.key.suffix(8))")
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)

                            Spacer()

                            if let kind = session.kind {
                                Text(kind)
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(kindColor(kind)))
                            }
                        }

                        HStack(spacing: 12) {
                            if let channel = session.channel {
                                Label(channel, systemImage: "number")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let model = session.model {
                                Label(model, systemImage: "cpu")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 12) {
                            if let tokens = session.contextTokens {
                                Text("\(tokens) 上下文令牌")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            if let total = session.totalTokens {
                                Text("\(total) 总计")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            if let updatedAt = session.updatedAt {
                                Text(relativeTime(updatedAt))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        addSessionToChannel(session)
                    } label: {
                        Label("添加到频道", systemImage: "plus")
                    }
                    .tint(.openClawRed)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("会话")
        .refreshable {
            await viewModel.listSessions()
        }
        .task {
            await viewModel.listSessions()
        }
        .alert("已添加到频道", isPresented: $showAddedAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("「\(addedChannelName)」已加入频道列表，返回主界面后即可在频道里接着聊。")
        }
        .overlay {
            if viewModel.isLoading && viewModel.sessions.isEmpty {
                ProgressView()
            }
        }
    }

    private func addSessionToChannel(_ session: SessionEntry) {
        let agentId = session.key.split(separator: ":").dropFirst().first.map(String.init) ?? "main"
        let title = viewModel.sessionTitles[session.key]
            ?? ToolsViewModel.friendlyTitle(for: session.key)
            ?? "会话 \(session.key.suffix(8))"
        var channel = Channel(name: title, agentId: agentId, systemEmoji: "💬")
        channel.serverSessionKey = session.key
        ChannelStore.shared.add(channel)
        addedChannelName = title
        showAddedAlert = true
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "main": return .openClawRed
        case "group": return .blue
        case "cron": return .orange
        case "hook": return .purple
        case "node": return .green
        default: return .gray
        }
    }

    private func relativeTime(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Session Detail

private struct SessionDetailView: View {
    @Bindable var viewModel: ToolsViewModel
    let session: SessionEntry
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("视图", selection: $selectedTab) {
                Text("状态").tag(0)
                Text("历史记录").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            if selectedTab == 0 {
                StatusTab(viewModel: viewModel)
            } else {
                HistoryTab(viewModel: viewModel)
            }
        }
        .navigationTitle(viewModel.sessionTitles[session.key] ?? ToolsViewModel.friendlyTitle(for: session.key) ?? "会话 \(session.key.suffix(8))")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.getSessionStatus(sessionKey: session.key)
            await viewModel.getSessionHistory(sessionKey: session.key)
        }
    }
}

private struct StatusTab: View {
    @Bindable var viewModel: ToolsViewModel

    var body: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.sessionStatus == nil {
                ProgressView()
                    .padding(.top, 40)
            } else if let text = viewModel.sessionStatus {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                Text("暂无状态")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
            }
        }
    }
}

private struct HistoryTab: View {
    @Bindable var viewModel: ToolsViewModel

    var body: some View {
        if viewModel.isLoading && viewModel.sessionHistory == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let history = viewModel.sessionHistory {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let bytes = history.bytes {
                        Text("\(history.messages.count) 条消息 · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }

                    ForEach(history.messages.reversed()) { message in
                        HistoryMessageRow(message: message)
                    }
                }
                .padding(.vertical)
            }
        } else if let error = viewModel.errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .padding()
        } else {
            Text("暂无历史记录")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct HistoryMessageRow: View {
    let message: SessionHistoryMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: message.role == "user" ? "person.fill" : "cpu")
                    .foregroundStyle(message.role == "user" ? .blue : Color.openClawRed)
                    .font(.caption)

                Text(message.role)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(message.role == "user" ? .blue : Color.openClawRed)

                if let model = message.model {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let ts = message.timestamp {
                    Text(formatDateTime(ts))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let stopReason = message.stopReason, stopReason == "toolUse" {
                Label("工具调用", systemImage: "arrow.right.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(Array(message.content.enumerated()), id: \.offset) { _, content in
                if content.type == "text", let text = content.text, !text.isEmpty {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                } else if content.type == "thinking" {
                    DisclosureGroup {
                        Text(content.thinking ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Label("思考过程", systemImage: "brain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if content.type == "toolCall", let name = content.name {
                    DisclosureGroup {
                        Text(content.text ?? content.thinking ?? "无参数")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Label("工具：\(name)", systemImage: "wrench.and.screwdriver")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(message.role == "user" ? Color.blue.opacity(0.08) : Color(.systemGray6))
        )
        .padding(.horizontal)
    }

    private func formatDateTime(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
