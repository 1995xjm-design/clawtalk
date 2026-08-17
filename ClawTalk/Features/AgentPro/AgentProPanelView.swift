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
    @State private var dreamDiary: DreamDiaryResponse?
    @State private var operators: [GatewayOperatorFleet.OperatorSessionInfo] = []
    @State private var skillQuery = ""
    @State private var skillInstallSlug = ""
    @State private var selectedCronJob: CronJob?
    @State private var cronDetail: CronJob?
    @State private var showCronDetail = false
    @State private var showDreamDiary = false
    @State private var lastSearchSummary: String?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let lastSearchSummary {
                Section {
                    Label(lastSearchSummary, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
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
            dreamingSection
            nodesSection
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
        .sheet(isPresented: $showCronDetail) {
            if let selectedCronJob {
                NavigationStack {
                    cronDetailSheet(selectedCronJob)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showDreamDiary) {
            NavigationStack {
                dreamDiarySheet
            }
            .presentationDetents([.medium, .large])
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
                if let cacheStatus = usage.cacheStatus {
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
                Button("详情") {
                    selectedCronJob = job
                    showCronDetail = true
                    Task { await loadCronDetail(job) }
                }
                .font(.caption)
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
                if let items = skills.skills {
                    if items.isEmpty {
                        Text("无已安装技能")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
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
                    }
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
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("搜索 ClawHub 技能", text: $skillQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("搜索") {
                        Task { await searchSkills() }
                    }
                    .font(.caption)
                    .disabled(busy || skillQuery.isEmpty)
                }
                HStack(spacing: 8) {
                    TextField("clawhub slug 安装", text: $skillInstallSlug)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("安装") {
                        Task { await installSkill() }
                    }
                    .font(.caption)
                    .disabled(busy || skillInstallSlug.isEmpty)
                }
            }
            .padding(.top, 4)
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
        } footer: {
            Button("保存配置（config.patch）") {
                Task { await saveConfig() }
            }
            .font(.caption)
            .disabled(busy || configText == nil)
        }
    }

    // MARK: - Dreaming（doctor.memory.dreamDiary）

    private var dreamingSection: some View {
        Section {
            if let dreamDiary {
                let days = dreamDiary.days ?? []
                if days.isEmpty {
                    Text("暂无梦境记录")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(days) { day in
                        HStack {
                            Text(day.date ?? "—")
                                .font(.subheadline)
                            Spacer()
                            Text("\(day.entries ?? 0) 条")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                loadingRow
            }
        } header: {
            HStack {
                Text("记忆梦境")
                Spacer()
                Button("查看") {
                    showDreamDiary = true
                }
                .font(.caption)
                .disabled(busy)
            }
        }
    }

    private var dreamDiarySheet: some View {
        List {
            if let dreamDiary {
                if let days = dreamDiary.days, !days.isEmpty {
                    ForEach(days) { day in
                        Section(day.date ?? "—") {
                            Text(day.summary ?? "\(day.entries ?? 0) 条记录")
                                .font(.footnote)
                        }
                    }
                }
                if let entries = dreamDiary.entries, !entries.isEmpty {
                    ForEach(entries) { entry in
                        Section(entry.date ?? "梦境") {
                            Text(entry.summary ?? entry.content ?? "")
                                .font(.footnote)
                            if let tags = entry.tags, !tags.isEmpty {
                                Text(tags.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("加载中…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("记忆梦境")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { showDreamDiary = false }
            }
        }
    }

    // MARK: - Nodes（operator.read）

    private var nodesSection: some View {
        Section {
            if operators.isEmpty && !busy {
                Text("无 operator 设备")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(operators) { op in
                HStack(spacing: 8) {
                    Circle()
                        .fill((op.connected ?? false) ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(op.displayName ?? op.deviceId ?? "设备")
                            .font(.subheadline.weight(.medium))
                        if let deviceId = op.deviceId {
                            Text(deviceId)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(op.kind ?? op.role ?? "operator")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("节点舰队")
                Spacer()
                Button("刷新") {
                    Task { await loadNodes() }
                }
                .font(.caption)
                .disabled(busy)
            }
        }
    }

    // MARK: - Cron Detail

    private func cronDetailSheet(_ job: CronJob) -> some View {
        List {
            Section("任务") {
                row("ID", job.id ?? "—", mono: true)
                row("名称", job.name ?? "—")
                row("表达式", job.expression ?? "—", mono: true)
                row("状态", job.status ?? "—")
                row("上次运行", job.lastRunAt ?? "—")
                row("下次运行", job.nextRunAt ?? "—")
            }
            if let cronDetail {
                Section("详情") {
                    if let status = cronDetail.status {
                        row("运行状态", status)
                    }
                    if let lastRunAt = cronDetail.lastRunAt {
                        row("上次运行", lastRunAt)
                    }
                    if let nextRunAt = cronDetail.nextRunAt {
                        row("下次运行", nextRunAt)
                    }
                }
            }
            Section {
                Button("立即运行") {
                    Task {
                        await runCronJob(job)
                        showCronDetail = false
                    }
                }
                .disabled(busy)
            }
        }
        .navigationTitle("定时任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadCronDetail(job)
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
            async let g: Void = loadDreamDiary()
            async let h: Void = loadNodes()
            _ = await (a, b, c, d, e, f, g, h)
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

    private func loadDreamDiary() async {
        do {
            let data = try await call("doctor.memory.dreamDiary", timeoutMs: 8)
            dreamDiary = decode(DreamDiaryResponse.self, from: data)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadNodes() async {
        do {
            let data = try await call("operator.read", params: ["includeTalkSecrets": AnyCodable(false)], timeoutMs: 12)
            let decoded = decode(GatewayOperatorFleet.OperatorListResponse.self, from: data)
            operators = decoded?.operators ?? []
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadCronDetail(_ job: CronJob) async {
        do {
            let data = try await call("cron.get", params: ["id": AnyCodable(job.id ?? "")], timeoutMs: 8)
            cronDetail = decode(CronJob.self, from: data)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func searchSkills() async {
        await run {
            let query = skillQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            let data = try await call("skills.search", params: ["query": AnyCodable(query)], timeoutMs: 20)
            let decoded = decode(SkillsSearchResponse.self, from: data)
            let results = decoded?.results ?? []
            let summary = results.isEmpty
                ? "未找到匹配技能"
                : "找到 \(results.count) 个技能：" + results.prefix(8).map { $0.name ?? $0.id ?? "—" }.joined(separator: "、")
            lastSearchSummary = summary
        }
    }

    private func installSkill() async {
        await run {
            let slug = skillInstallSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty else { return }
            let params = SkillsInstallParams(slug: slug, agentId: "main")
            let dict = try GatewayConnection.encodeParams(params)
            _ = try await call("skills.install", params: dict, timeoutMs: 125)
            lastSearchSummary = "已安装 \(slug)"
            skillInstallSlug = ""
            await loadSkills()
        }
    }

    private func saveConfig() async {
        await run {
            guard let configText, let data = configText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                lastSearchSummary = "配置不是合法 JSON"
                return
            }
            _ = try await call("config.patch", params: object.mapValues { AnyCodable($0) }, timeoutMs: 20)
            lastSearchSummary = "配置已保存"
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