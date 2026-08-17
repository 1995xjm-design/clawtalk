import SwiftUI

/// 会话中心（对齐官方 CommandCenterTab 精简）：
/// 拉取网关会话列表（sessions.list），按置顶/分类/未分组展示，支持打开会话与新建分组。
struct CommandCenterTab: View {
    var gatewayConnection: GatewayConnection

    @State private var sessions: [SessionEntry] = []
    @State private var busy = false
    @State private var errorText: String?
    @State private var newGroupName = ""
    @State private var showNewGroup = false

    private var groups: [String] { SessionGroupStore.load() }

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            if busy && sessions.isEmpty {
                Section {
                    HStack {
                        ProgressView()
                        Text("加载会话…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(CommandSessionGrouping.sections(from: sessions, knownGroups: groups)) { section in
                Section {
                    if section.entries.isEmpty {
                        Text("空分组")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(section.entries) { entry in
                        sessionRow(entry)
                    }
                } header: {
                    if section.showsHeader {
                        Text(section.title)
                    }
                }
            }
            Section("分组") {
                ForEach(groups, id: \.self) { name in
                    Text(name)
                        .font(.subheadline)
                }
                Button {
                    showNewGroup = true
                } label: {
                    Label("新建分组", systemImage: "folder.badge.plus")
                }
            }
        }
        .navigationTitle("会话中心")
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
        .alert("新建分组", isPresented: $showNewGroup) {
            TextField("分组名", text: $newGroupName)
            Button("创建") {
                let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    SessionGroupStore.remember(name)
                    newGroupName = ""
                }
            }
            Button("取消", role: .cancel) {
                newGroupName = ""
            }
        }
        .task { await refresh() }
    }

    private func sessionRow(_ entry: SessionEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind == "agent" ? "person.crop.circle" : "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName ?? entry.label ?? entry.key)
                    .font(.subheadline.weight(.medium))
                Text(entry.key)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let updatedAt = entry.updatedAt {
                Text(Self.timeText(updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let data = try await gatewayConnection.request(method: "sessions.list", params: nil, timeoutMs: 15)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            sessions = (try? decoder.decode(SessionsListResult.self, from: data))?.sessions ?? []
        } catch {
            errorText = error.localizedDescription
        }
    }

    static func timeText(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
