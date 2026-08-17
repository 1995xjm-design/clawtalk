import SwiftUI

/// 网关任务队列面板：tasks.list（双请求合并）+ tasks.get + tasks.cancel + tasks.recovery。
struct TasksPanelView: View {
    var gatewayConnection: GatewayConnection

    @State private var tasks: [TaskSummary] = []
    @State private var busy = false
    @State private var errorText: String?
    @State private var selectedTask: TaskSummary?
    @State private var showDetail = false

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if tasks.isEmpty && !busy {
                Section {
                    Text("暂无任务")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(tasks) { task in
                Button {
                    selectedTask = task
                    showDetail = true
                } label: {
                    taskRow(task)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    if task.status == "queued" || task.status == "running" {
                        Button("取消", role: .destructive) {
                            Task { await cancelTask(task) }
                        }
                    }
                }
            }
        }
        .navigationTitle("任务")
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
        .sheet(isPresented: $showDetail) {
            if let selectedTask {
                NavigationStack {
                    TaskDetailView(task: selectedTask, gatewayConnection: gatewayConnection)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .task {
            await refresh()
        }
    }

    private func taskRow(_ task: TaskSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(task.status))
                    .frame(width: 9, height: 9)
                Text(task.name ?? task.taskId ?? "任务")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(statusLabel(task.status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let agentId = task.agentId, !agentId.isEmpty {
                Text("agent: \(agentId)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let createdAt = task.createdAt, !createdAt.isEmpty {
                Text(createdAt)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "queued": return .orange
        case "running": return .blue
        case "completed": return .green
        case "failed": return .red
        case "cancelled": return .gray
        case "timed_out": return .purple
        default: return .gray
        }
    }

    private func statusLabel(_ status: String?) -> String {
        switch status {
        case "queued": return "排队中"
        case "running": return "运行中"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        case "timed_out": return "超时"
        default: return status ?? "—"
        }
    }

    // MARK: - RPC

    private func refresh() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            async let activeData = gatewayConnection.request(
                method: "tasks.list",
                params: ["status": AnyCodable(["queued", "running"]), "limit": AnyCodable(200)],
                timeoutMs: 20
            )
            async let doneData = gatewayConnection.request(
                method: "tasks.list",
                params: ["status": AnyCodable(["completed", "failed", "cancelled", "timed_out"]), "limit": AnyCodable(100)],
                timeoutMs: 20
            )
            let (active, done) = try await (activeData, doneData)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let activeList = (try? decoder.decode(TaskListResponse.self, from: active))?.tasks ?? []
            let doneList = (try? decoder.decode(TaskListResponse.self, from: done))?.tasks ?? []
            tasks = activeList + doneList
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func cancelTask(_ task: TaskSummary) async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            _ = try await gatewayConnection.request(
                method: "tasks.cancel",
                params: ["taskId": AnyCodable(task.taskId ?? "")],
                timeoutMs: 20
            )
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 任务详情（tasks.get + 取消按钮）。
private struct TaskDetailView: View {
    let task: TaskSummary
    var gatewayConnection: GatewayConnection

    @State private var detail: TaskSummary?
    @State private var busy = false
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section("任务") {
                row("ID", task.taskId ?? "—", mono: true)
                row("名称", task.name ?? "—")
                row("状态", statusText(task.status ?? "—"))
                if let agentId = task.agentId {
                    row("Agent", agentId)
                }
                if let createdAt = task.createdAt {
                    row("创建时间", createdAt)
                }
            }
            if let detail {
                Section("详情") {
                    if let result = detail.resultText {
                        Text(result)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if let error = detail.errorText {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let output = detail.outputText {
                        Text(output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            Section {
                if task.status == "queued" || task.status == "running" {
                    Button("取消任务", role: .destructive) {
                        Task { await cancel() }
                    }
                    .disabled(busy)
                }
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            let data = try await gatewayConnection.request(
                method: "tasks.get",
                params: ["taskId": AnyCodable(task.taskId ?? "")],
                timeoutMs: 20
            )
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            detail = try? decoder.decode(TaskSummary.self, from: data)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func cancel() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await gatewayConnection.request(
                method: "tasks.cancel",
                params: ["taskId": AnyCodable(task.taskId ?? "")],
                timeoutMs: 20
            )
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .caption.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "queued": return "排队中"
        case "running": return "运行中"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        case "timed_out": return "超时"
        default: return status
        }
    }
}

// MARK: - Models

struct TaskListResponse: Codable {
    var tasks: [TaskSummary]?
    var total: Int?
}

struct TaskSummary: Codable, Identifiable {
    var id: String? { taskId }
    var taskId: String?
    var name: String?
    var status: String?
    var agentId: String?
    var createdAt: String?
    var updatedAt: String?
    var resultText: String?
    var errorText: String?
    var outputText: String?
}