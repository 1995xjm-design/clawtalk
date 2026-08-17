import Foundation
import SwiftUI

/// 后台任务（对齐官方 MobileBackgroundTask）：tasks.get/list 移动端任务模型。
struct MobileBackgroundTask: Decodable, Identifiable, Equatable {
    struct Timestamp: Decodable, Equatable {
        let milliseconds: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self.milliseconds = number
                return
            }
            let value = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a millisecond timestamp or ISO-8601 date")
            }
            self.milliseconds = date.timeIntervalSince1970 * 1000
        }
    }

    let id: String
    let status: String
    let runtime: String?
    let title: String?
    let agentId: String?
    let sessionKey: String?
    let childSessionKey: String?
    let createdAt: Timestamp?
    let updatedAt: Timestamp?
    let startedAt: Timestamp?
    let endedAt: Timestamp?
    let lastActivity: String?
    let progressSummary: String?
    let terminalSummary: String?
    let error: String?
    let prompt: String?

    var displayTitle: String {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? id.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "后台任务"
    }

    var isActive: Bool { status == "queued" || status == "running" }

    var statusLabel: String {
        switch status {
        case "queued": return "排队中"
        case "running": return "运行中"
        case "completed": return "已完成"
        default: return "失败"
        }
    }

    var runtimeLabel: String {
        switch runtime {
        case "subagent": return "子代理"
        case "cron": return "定时"
        case "acp": return "ACP"
        case "cli": return "CLI"
        default: return "任务"
        }
    }

    var output: String? {
        let candidates = (status == "failed" || status == "timed_out")
            ? [error, terminalSummary, lastActivity, progressSummary]
            : [terminalSummary, error, lastActivity, progressSummary]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }.first
    }

    var activityMilliseconds: Double {
        updatedAt?.milliseconds ?? endedAt?.milliseconds
            ?? startedAt?.milliseconds ?? createdAt?.milliseconds ?? 0
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 后台任务列表加载（对齐官方 MobileBackgroundTaskList）：活跃在前，终态在后。
enum MobileBackgroundTaskList {
    @MainActor
    static func load(
        request: (_ status: [String], _ limit: Int) async throws -> [MobileBackgroundTask]) async throws
        -> [MobileBackgroundTask]
    {
        let active = try await request(["queued", "running"], 200)
        let finished = try await request(["completed", "failed", "cancelled", "timed_out"], 100)
        return merge(recent: finished, active: active)
    }

    static func merge(recent: [MobileBackgroundTask], active: [MobileBackgroundTask]) -> [MobileBackgroundTask] {
        var byId: [String: MobileBackgroundTask] = [:]
        for task in recent + active {
            guard let current = byId[task.id] else {
                byId[task.id] = task
                continue
            }
            byId[task.id] = current.updatedAt?.milliseconds ?? 0 >= task.updatedAt?.milliseconds ?? 0 ? current : task
        }
        return byId.values.sorted { $0.activityMilliseconds > $1.activityMilliseconds }
    }
}

/// 后台任务界面（对齐官方 BackgroundTasksScreen 精简）：tasks.list/get。
struct BackgroundTasksScreen: View {
    var gatewayConnection: GatewayConnection

    @State private var tasks: [MobileBackgroundTask] = []
    @State private var selectedTask: MobileBackgroundTask?
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
            Section("后台任务") {
                if tasks.isEmpty && !busy {
                    Text("无后台任务")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in
                    Button {
                        selectedTask = task
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(task.isActive ? Color.blue : (task.status == "completed" ? Color.green : Color.gray))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.displayTitle)
                                    .font(.subheadline.weight(.medium))
                                Text("\(task.runtimeLabel) · \(task.statusLabel)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("后台任务")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedTask) { task in
            NavigationStack {
                BackgroundTaskDetailScreen(task: task)
            }
            .presentationDetents([.medium, .large])
        }
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

    private func refresh() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            tasks = try await MobileBackgroundTaskList.load { status, limit in
                let data = try await gatewayConnection.request(
                    method: "tasks.list",
                    params: [
                        "status": AnyCodable(status),
                        "limit": AnyCodable(limit),
                        "agentId": AnyCodable("main"),
                    ],
                    timeoutMs: 20)
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return (try? decoder.decode(MobileBackgroundTasksEnvelope.self, from: data))?.tasks ?? []
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct MobileBackgroundTasksEnvelope: Decodable {
    let tasks: [MobileBackgroundTask]
}

/// 后台任务详情（对齐官方 BackgroundTaskDetailScreen 精简）。
struct BackgroundTaskDetailScreen: View {
    let task: MobileBackgroundTask
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("状态") {
                row("ID", task.id, mono: true)
                row("状态", task.statusLabel)
                row("运行时", task.runtimeLabel)
                if let agentId = task.agentId { row("代理", agentId) }
                if let sessionKey = task.sessionKey { row("会话", sessionKey, mono: true) }
            }
            Section("时间") {
                if let created = task.createdAt { row("创建", dateText(created.milliseconds)) }
                if let started = task.startedAt { row("开始", dateText(started.milliseconds)) }
                if let ended = task.endedAt { row("结束", dateText(ended.milliseconds)) }
            }
            if let output = task.output {
                Section("输出") {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .caption.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func dateText(_ ms: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
