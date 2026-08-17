import SwiftUI

/// 自动化面板（cron.get 详情 + 最近运行结果，简化版 AgentAutomationDetailScreen）。
struct AgentAutomationPanelView: View {
    var gatewayConnection: GatewayConnection

    @State private var jobs: [CronJob] = []
    @State private var selectedJob: CronJob?
    @State private var detail: CronJob?
    @State private var showDetail = false
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
            Section("自动化任务") {
                if jobs.isEmpty && !busy {
                    Text("无自动化任务")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(jobs) { job in
                    Button {
                        selectedJob = job
                        showDetail = true
                        Task { await loadDetail(job) }
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill((job.enabled ?? false) ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.name ?? job.id ?? "任务")
                                    .font(.subheadline.weight(.medium))
                                if let expression = job.expression {
                                    Text(expression)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(job.status ?? "—")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("自动化")
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
            if let selectedJob {
                NavigationStack {
                    detailList(selectedJob)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .task {
            await refresh()
        }
    }

    private func detailList(_ job: CronJob) -> some View {
        List {
            Section("任务") {
                row("ID", job.id ?? "—", mono: true)
                row("名称", job.name ?? "—")
                row("表达式", job.expression ?? "—", mono: true)
                row("启用", (job.enabled ?? false) ? "是" : "否")
            }
            if let detail {
                Section("详情") {
                    if let lastRunAt = detail.lastRunAt { row("上次运行", lastRunAt) }
                    if let nextRunAt = detail.nextRunAt { row("下次运行", nextRunAt) }
                    if let status = detail.status { row("状态", status) }
                }
            }
            Section {
                Button("立即运行", role: nil) {
                    Task { await runNow(job) }
                }
                .disabled(busy)
            }
        }
        .navigationTitle("自动化详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { showDetail = false }
            }
        }
    }

    private func refresh() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let data = try await gatewayConnection.request(method: "cron.list", params: [
                "includeDisabled": AnyCodable(true),
                "limit": AnyCodable(200)
            ], timeoutMs: 12)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            jobs = (try? decoder.decode(CronListResponse.self, from: data))?.jobs ?? []
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadDetail(_ job: CronJob) async {
        do {
            let data = try await gatewayConnection.request(method: "cron.get", params: ["id": AnyCodable(job.id ?? "")], timeoutMs: 8)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            detail = try? decoder.decode(CronJob.self, from: data)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func runNow(_ job: CronJob) async {
        busy = true
        defer { busy = false }
        do {
            let infoData = try await gatewayConnection.request(method: "system.info", timeoutMs: 12)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let info = try? decoder.decode(SystemInfo.self, from: infoData)
            var params: [String: AnyCodable] = ["id": AnyCodable(job.id ?? "")]
            if let instanceID = info?.processInstanceId {
                params["expectedProcessInstanceId"] = AnyCodable(instanceID)
            }
            _ = try await gatewayConnection.request(method: "cron.run", params: params, timeoutMs: 20)
            await loadDetail(job)
        } catch {
            errorText = error.localizedDescription
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
}