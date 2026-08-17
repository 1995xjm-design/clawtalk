import SwiftUI

/// Agent 工作区文件浏览（agents.workspace.list / agents.workspace.get）。
struct AgentWorkspaceFilesView: View {
    var gatewayConnection: GatewayConnection

    @State private var entries: [WorkspaceEntry] = []
    @State private var selectedPath: String?
    @State private var fileContent: String?
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
            Section("工作区文件") {
                if entries.isEmpty && !busy {
                    Text("无文件或网关未支持 agents.workspace.*")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    Button {
                        selectedPath = entry.path
                        Task { await openFile(entry) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.isDirectory == true ? "folder.fill" : "doc.fill")
                                .foregroundStyle(entry.isDirectory == true ? Color.openClawRed : .secondary)
                            Text(entry.name ?? entry.path ?? "—")
                                .font(.subheadline)
                            Spacer()
                            if let size = entry.size {
                                Text(sizeText(size))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let fileContent {
                Section("内容") {
                    Text(fileContent)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("工作区文件")
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

    private func refresh() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let data = try await gatewayConnection.request(method: "agents.workspace.list", params: ["path": AnyCodable("/")], timeoutMs: 20)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            entries = (try? decoder.decode(WorkspaceListResponse.self, from: data))?.entries ?? []
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func openFile(_ entry: WorkspaceEntry) async {
        guard entry.isDirectory != true else {
            busy = true
            defer { busy = false }
            do {
                let data = try await gatewayConnection.request(method: "agents.workspace.list", params: ["path": AnyCodable(entry.path ?? "/")], timeoutMs: 20)
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                entries = (try? decoder.decode(WorkspaceListResponse.self, from: data))?.entries ?? []
            } catch {
                errorText = error.localizedDescription
            }
            return
        }
        busy = true
        defer { busy = false }
        do {
            let data = try await gatewayConnection.request(method: "agents.workspace.get", params: ["path": AnyCodable(entry.path ?? "")], timeoutMs: 20)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            fileContent = (try? decoder.decode(WorkspaceGetResponse.self, from: data))?.content
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func sizeText(_ size: Int) -> String {
        if size >= 1_000_000 { return String(format: "%.1fMB", Double(size) / 1_000_000) }
        if size >= 1_000 { return String(format: "%.1fKB", Double(size) / 1_000) }
        return "\(size)B"
    }
}

struct WorkspaceEntry: Codable, Identifiable {
    var id: String? { path }
    var path: String?
    var name: String?
    var isDirectory: Bool?
    var size: Int?
    var modifiedAt: String?
}

struct WorkspaceListResponse: Codable {
    var entries: [WorkspaceEntry]?
}

struct WorkspaceGetResponse: Codable {
    var content: String?
    var path: String?
}