import SwiftUI

struct SessionsView: View {
    @Bindable var viewModel: ToolsViewModel
    @State private var selectedSession: SessionEntry?
    @State private var showAddedAlert = false
    @State private var addedChannelName = ""
    /// 本地置顶/归档标记（UserDefaults 独立键，不影响网关数据）
    @State private var pinnedKeys = SessionPinArchiveStore.pinnedKeys()
    @State private var archivedKeys = SessionPinArchiveStore.archivedKeys()
    @State private var showExportPicker = false
    /// 网关会话入口模式：非 nil 时点击会话直接回调（进入聊天），不再进入会话详情
    var onSelectSession: ((SessionEntry) -> Void)?

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
            } else if !viewModel.sessions.isEmpty && orderedSessions.isEmpty && !viewModel.isLoading {
                // 全部会话已归档时的诚实空状态
                ContentUnavailableView(
                    "会话已全部归档",
                    systemImage: "archivebox",
                    description: Text("点击右上角「归档」可查看并恢复。")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(orderedSessions) { session in
                sessionRow(session)
                    .swipeActions(edge: .trailing) {
                        Button {
                            toggleArchive(session)
                        } label: {
                            Label(archivedKeys.contains(session.key) ? "取消归档" : "归档", systemImage: "archivebox")
                        }
                        .tint(.orange)

                        Button {
                            togglePin(session)
                        } label: {
                            Label(pinnedKeys.contains(session.key) ? "取消置顶" : "置顶", systemImage: "pin")
                        }
                        .tint(.openClawRed)

                        Button {
                            addSessionToChannel(session)
                        } label: {
                            Label("添加到频道", systemImage: "plus")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle(onSelectSession == nil ? "会话" : "网关会话")
        .refreshable {
            await viewModel.listSessions()
        }
        .task {
            await viewModel.listSessions()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ArchivedSessionsView(viewModel: viewModel, archivedKeys: $archivedKeys)
                } label: {
                    Image(systemName: "archivebox")
                }
                .accessibilityLabel("归档")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showExportPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出会话")
            }
        }
        .sheet(isPresented: $showExportPicker) {
            SessionExportPickerView(viewModel: viewModel)
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

    /// 主列表顺序：置顶优先，其余按网关返回顺序；归档会话不在主列表显示。
    private var orderedSessions: [SessionEntry] {
        let visible = viewModel.sessions.filter { !archivedKeys.contains($0.key) }
        let pinned = visible.filter { pinnedKeys.contains($0.key) }
        let others = visible.filter { !pinnedKeys.contains($0.key) }
        return pinned + others
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionEntry) -> some View {
        if let onSelectSession {
            Button {
                onSelectSession(session)
            } label: {
                sessionRowContent(session)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                SessionDetailView(viewModel: viewModel, session: session)
            } label: {
                sessionRowContent(session)
            }
        }
    }

    private func sessionRowContent(_ session: SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if pinnedKeys.contains(session.key) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.openClawRed)
                }

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

    private func togglePin(_ session: SessionEntry) {
        if pinnedKeys.contains(session.key) {
            pinnedKeys.remove(session.key)
            SessionPinArchiveStore.setPinned(session.key, false)
        } else {
            pinnedKeys.insert(session.key)
            SessionPinArchiveStore.setPinned(session.key, true)
        }
    }

    private func toggleArchive(_ session: SessionEntry) {
        if archivedKeys.contains(session.key) {
            archivedKeys.remove(session.key)
            SessionPinArchiveStore.setArchived(session.key, false)
        } else {
            archivedKeys.insert(session.key)
            pinnedKeys.remove(session.key)
            SessionPinArchiveStore.setPinned(session.key, false)
            SessionPinArchiveStore.setArchived(session.key, true)
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

// MARK: - 会话置顶/归档本地存储

/// 会话置顶/归档标记：UserDefaults 独立键（String 数组），不影响网关数据。
private enum SessionPinArchiveStore {
    private static let pinnedKey = "clawtalk_sessions_pinned_v1"
    private static let archivedKey = "clawtalk_sessions_archived_v1"

    static func pinnedKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [])
    }

    static func archivedKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: archivedKey) ?? [])
    }

    static func setPinned(_ key: String, _ pinned: Bool) {
        var keys = pinnedKeys()
        if pinned { keys.insert(key) } else { keys.remove(key) }
        UserDefaults.standard.set(Array(keys), forKey: pinnedKey)
    }

    static func setArchived(_ key: String, _ archived: Bool) {
        var keys = archivedKeys()
        if archived { keys.insert(key) } else { keys.remove(key) }
        UserDefaults.standard.set(Array(keys), forKey: archivedKey)
    }
}

// MARK: - 归档页

/// 归档会话页：从主列表隐藏的会话在这里恢复，诚实空状态。
private struct ArchivedSessionsView: View {
    @Bindable var viewModel: ToolsViewModel
    @Binding var archivedKeys: Set<String>

    private var archivedSessions: [SessionEntry] {
        viewModel.sessions.filter { archivedKeys.contains($0.key) }
    }

    var body: some View {
        Group {
            if archivedSessions.isEmpty {
                ContentUnavailableView(
                    "暂无归档",
                    systemImage: "archivebox",
                    description: Text("在会话列表左滑可归档，归档后可在此恢复。")
                )
            } else {
                List {
                    ForEach(archivedSessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.sessionTitles[session.key]
                                    ?? ToolsViewModel.friendlyTitle(for: session.key)
                                    ?? "会话 \(session.key.suffix(8))")
                                    .font(.body)
                                    .fontWeight(.medium)
                                if let updatedAt = session.updatedAt {
                                    Text(relativeTime(updatedAt))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer()

                            Button("恢复") {
                                restore(session)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .onDelete { offsets in
                        let toRestore = offsets.map { archivedSessions[$0] }
                        for session in toRestore {
                            restore(session)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("归档会话")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func restore(_ session: SessionEntry) {
        archivedKeys.remove(session.key)
        SessionPinArchiveStore.setArchived(session.key, false)
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
    @State private var showExport = false

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
        .navigationTitle(detailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showExport = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出会话")
            }
        }
        .sheet(isPresented: $showExport) {
            SessionExportView(viewModel: viewModel, source: .gatewaySession(session, title: detailTitle))
        }
        .task {
            await viewModel.getSessionStatus(sessionKey: session.key)
            await viewModel.getSessionHistory(sessionKey: session.key)
        }
    }

    private var detailTitle: String {
        viewModel.sessionTitles[session.key]
            ?? ToolsViewModel.friendlyTitle(for: session.key)
            ?? "会话 \(session.key.suffix(8))"
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
