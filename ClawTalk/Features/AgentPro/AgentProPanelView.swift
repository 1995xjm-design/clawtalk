import SwiftUI

/// AgentPro 高级面板：usage.cost / cron.* / skills.* / doctor.memory.* / system.info / config.*。
/// 全部走网关 WebSocket RPC（GatewayConnection.request，已支持 timeoutMs 透传）。
struct AgentProPanelView: View {
    var gatewayConnection: GatewayConnection

    @State private var systemInfo: SystemInfo?
    @State private var usage: UsageCostResponse?
    @State private var cronJobs: [CronJob] = []
    @State private var skills: SkillsStatusResponse?
    @State private var doctorStatus: DoctorMemoryStatus?
    @State private var configText: String?
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

            systemSection
            usageSection
            cronSection
            skillsSection
            doctorSection
            configSection
        }
        .navigationTitle("网关高级面板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    if busy {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(busy)
            }
        }
        .task {
            await refreshAll()
        }
    }

    // MARK: - System

    private var systemSection: some View {
        Section("系统信息") {
            if let systemInfo {
                row("进程实例 ID", systemInfo.processInstanceId ?? "—", mono: true)
                row("版本", systemInfo.version ?? "—")
                row("平台", systemInfo.platform ?? "—")
                row("主机名", systemInfo.hostname ?? "—")
                if let uptime = systemInfo.uptimeMs {
                    row("运行时长", formatUptime(uptime))
                }
            } else {
                loadingRow
            }
        }
    }

    // MARK: - Usage

    private var usageSection: some View {
        Section {
            if let usage {
                if let totals = usage.totals {
                    row("总 Token", formatNumber(totals.totalTokens))
                    row("总费用", formatCost(totals.totalCost))
                }
                if let cacheStatus {
                    row("缓存状态", cacheStatus)
                }
                if let daily = usage.daily, !daily.isEmpty {
                    ForEach(daily) { day in
                        HStack {
                            Text(day.date ?? "—")
                                .font(.subheadline)
                            Spacer()
                            Text(formatNumber(day.totalTokens))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(formatCost(day.totalCost))
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                        }
                    }
                }
            } else {
                loadingRow
            }
        } header: {
            HStack {
                Text("用量（近 31 天）")
                Spacer()
                Button("刷新") {
                    Task { await loadUsage() }
                }
                .font(.caption)
                .disabled(busy)
            }
        }
    }

    // MARK: - Cron

    private var cronSection: some View {
        Section {
            if cronJobs.isEmpty && !busy {
                Text("无定时任务")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(cronJobs) { job in
                cronRow(job)
            }
        } header: {
            HStack {
                Text("定时任务")
                Spacer()
                Button("刷新") {
                    Task { await loadCron() }
                }
                .font(.caption)
                .disabled(busy)
            }
        }
    }

    private func cronRow(_ job: CronJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill((job.enabled ?? false) ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(job.name ?? job.id ?? "未命名任务")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let status = job.status, !status.isEmpty {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let expression = job.expression {
                Text(expression)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button("立即运行") {
                    Task { await runCronJob(job) }
                }
                .font(.caption)
                .disabled(busy)
                Button((job.enabled ?? false) ? "暂停" : "启用") {
                    Task { await toggleCronJob(job) }
                }
                .font(.caption)
                .disabled(busy)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Skills

    private var skillsSection: some View {
        Section {
            if let skills {
                if let error = skills.error, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let items = skills.skills, !items.isEmpty {
                    ForEach(items) { skill in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name ?? skill.id ?? "—")
                                    .font(.subheadline.weight(.medium))
                                if let version = skill.version {
                                    Text("v\(version)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let enabled = skill.enabled {
                                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(enabled ? .green : .secondary)
                            }
                        }
                    }
                } else if items?.isEmpty != false {
                    Text("无已安装技能")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                loadingRow
            }
        } header: {
            HStack {
                Text("技能")
                Spacer()
                Button("刷新") {
                    Task { await loadSkills() }
                }
                .font(.caption)
                .disabled(busy)
            }
        }
    }

    // MARK: - Doctor / Memory

    private var doctorSection: some View {
        Section {
            if let doctorStatus {
                row("健康", doctorStatus.healthy == true ? "正常" : "异常")
                if let memoryCount = doctorStatus.memoryCount {
                    row("记忆条数", "\(memoryCount)")
                }
                if let lastDream = doctorStatus.lastDream {
                    row("上次梦境", lastDream)
                }
            } else {
                loadingRow
            }

            Button("刷新状态") {
                Task { await loadDoctor() }
            }
            .font(.subheadline)
            .disabled(busy)

            Button("回溯梦境（backfill）") {
                Task { await doctorAction("doctor.memory.backfillDreamDiary", timeoutMs: 30) }
            }
            .font(.subheadline)
            .disabled(busy)

            Button("修复梦境产物（repair）") {
                Task { await doctorAction("doctor.memory.repairDreamingArtifacts", timeoutMs: 30) }
            }
            .font(.subheadline)
            .disabled(busy)

            Button("去重梦境日记（dedupe）") {
                Task { await doctorAction("doctor.memory.dedupeDreamDiary", timeoutMs: 30) }
            }
            .font(.subheadline)
            .disabled(busy)
        } header: {
            HStack {
                Text("记忆诊断")
                Spacer()
                Button("刷新") {
                    Task { await loadDoctor() }
                }
                .font(.caption)
                .disabled(busy)
            }
        }
    }

    // MARK: - Config

    private var configSection: some View {
        Section {
            if let configText {
                Text(configText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else {
                loadingRow
            }
        } header: {
            HStack {
                Text("网关配置")
                Spacer()
                Button("读取") {
                    Task { await loadConfig() }
                }
                .font(.caption)
                .disabled(busy)
            }
        }
    }

    // MARK: - Shared UI

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("加载中…")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: - RPC

    private func call(_ method: String, params: [String: AnyCodable]? = nil, timeoutMs: Double? = nil) async throws -> Data {
        try await gatewayConnection.request(method: method, params: params, timeoutMs: timeoutMs)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
    }

    private func run(_ action: @escaping () async throws -> Void) async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            try await action()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func refreshAll() async {
        await run {
            async let a: Void = loadSystem()
            async let b: Void = loadUsage()
            async let c: Void = loadCron()
            async let d: Void = loadSkills()
            async let e: Void = loadDoctor()
            async let f: Void = loadConfig()
            _ = await (a, b, c, d, e, f)
        }
    }

    private func loadSystem() async {
        do {
            let data = try await call("system.info", timeoutMs: 12)
            systemInfo = decode(SystemInfo.self, from: data)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadUsage() async {
        do {
            let data = try await call("usage.cost", params: ["days": AnyCodable(31)], timeoutMs: 12)
            usage = decode(UsageCostResponse.self, from: data)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadCron() async {
        do {
            let data = try await call("cron.list", params: [
                "includeDisabled": AnyCodable(true),
                "limit": AnyCodable(200),
                "sortBy": AnyCodable("name"),
                "sortDir": AnyCodable("asc")
            ], timeoutMs: 12)
            let decoded = decode(CronListResponse.self, from: data)
            cronJobs = decoded?.jobs ?? []
            if let rev = decoded?.snapshotRevision {
                snapshotRevision = rev
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func runCronJob(_ job: CronJob) async {
        await run {
            // cron.run 需先取 processinstanceid 做乐观锁校验
            var instanceID: String?
            if systemInfo?.processInstanceId == nil {
                let infoData = try await call("system.info", timeoutMs: 12)
                systemInfo = decode(SystemInfo.self, from: infoData)
            }
            instanceID = systemInfo?.processInstanceId
            var params: [String: AnyCodable] = ["id": AnyCodable(job.id ?? "")]
            if let instanceID {
                params["expectedProcessInstanceId"] = AnyCodable(instanceID)
            }
            let data = try await call("cron.run", params: params, timeoutMs: 20)
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                errorText = nil
            }
            await loadCron()
        }
    }

    private func toggleCronJob(_ job: CronJob) async {
        await run {
            let params: [String: AnyCodable] = [
                "id": AnyCodable(job.id ?? ""),
                "expectedConfigRevision": AnyCodable(job.configRevision ?? 0),
                "patch": AnyCodable(["enabled": AnyCodable(!(job.enabled ?? false))])
            ]
            _ = try await call("cron.update", params: params, timeoutMs: 20)
            await loadCron()
        }
    }

    private func loadSkills() async {
        do {
            let data = try await call("skills.status", params: ["agentId": AnyCodable("main")], timeoutMs: 20)
            skills = decode(SkillsStatusResponse.self, from: data)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadDoctor() async {
        do {
            let data = try await call("doctor.memory.status", timeoutMs: 8)
            doctorStatus = decode(DoctorMemoryStatus.self, from: data)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func doctorAction(_ method: String, timeoutMs: Double) async {
        await run {
            _ = try await call(method, timeoutMs: timeoutMs)
            await loadDoctor()
        }
    }

    private func loadConfig() async {
        do {
            let data = try await call("config.get", timeoutMs: 12)
            configText = prettyJSONText(data)
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Formatting

    private func formatNumber(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return String(format: "%.0f", value)
    }

    private func formatCost(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.4f", value)
    }

    private func formatUptime(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }
}