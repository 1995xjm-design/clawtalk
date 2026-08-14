import Foundation
import Observation

/// 自动化任务列表管理：
/// - 本地模型 + UserDefaults 持久化（增删改查立即生效）
/// - 网关 cron 接口预留（端点接线后自动同步创建/删除/启停）
@Observable
@MainActor
final class AutomationViewModel {

    // MARK: - 状态

    /// 本机任务列表（数据源）
    private(set) var tasks: [AutomationTask] = []
    /// 任务运行历史（taskID -> 最近运行结果，用于「历史」入口）
    private(set) var runHistories: [String: [AutomationRunResult]] = [:]
    var isLoading = false
    var errorMessage: String? {
        didSet { if let errorMessage { LogCollector.record(module: "自动化", errorMessage) } }
    }
    /// 网关同步状态提示（空则不显示）
    var gatewayStatusText: String?

    // MARK: - 私有

    private let settings: SettingsStore?
    private let gatewayClient: GatewayCronClient?
    private let storageKey = "clawtalk_automation_tasks_v1"
    private let historyKey = "clawtalk_automation_run_history_v1"

    init(settings: SettingsStore? = nil) {
        self.settings = settings
        if let settings, settings.isConfigured {
            gatewayClient = GatewayCronClient(
                gatewayURL: settings.settings.gatewayURL,
                token: OpenClawClient.resolveHTTPToken(
                    settingsToken: settings.gatewayToken,
                    gatewayURL: settings.settings.gatewayURL
                )
            )
            gatewayStatusText = "已配置网关；cron 接口将自动探测后同步"
        } else {
            gatewayClient = nil
            gatewayStatusText = "网关未配置，仅显示本机任务"
        }
        loadLocalData()
    }

    // MARK: - 查询

    func task(withID id: String) -> AutomationTask? {
        tasks.first { $0.id == id }
    }

    func history(for taskID: String) -> [AutomationRunResult] {
        runHistories[taskID] ?? []
    }

    // MARK: - 增删改（本地立即生效 + 预留网关同步）

    @discardableResult
    func addTask(_ task: AutomationTask) -> AutomationTask {
        tasks.append(task)
        persist()
        Task { await pushCreate(task) }
        return task
    }

    func updateTask(_ task: AutomationTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        persist()
        Task { await pushUpdate(task) }
    }

    func deleteTask(id: String) {
        tasks.removeAll { $0.id == id }
        runHistories[id] = nil
        persist()
        Task { await pushDelete(id: id) }
    }

    func setEnabled(_ enabled: Bool, for taskID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].enabled = enabled
        persist()
        Task { await pushEnabledChange(id: taskID, enabled: enabled) }
    }

    /// 记录一次运行结果（网关执行回调/本地测试用；预留接口）
    func recordRun(_ result: AutomationRunResult, for taskID: String) {
        var records = runHistories[taskID] ?? []
        records.insert(result, at: 0)
        runHistories[taskID] = Array(records.prefix(20))
        persist()
    }

    // MARK: - 网关同步（预留）

    /// 从网关拉取 cron 任务并合并到本机（端点自动探测，探测不到诚实提示）。
    func refresh() async {
        guard let client = gatewayClient else { return }
        isLoading = true
        errorMessage = nil
        // 线 I：候选端点自动探测（/cron/tasks、/cron/list；OpenClaw 官方 WS cron.list 仅提示）。
        // 探测成功才发起请求，避免对不存在的端点发请求拿到网页 HTML 触发 JSON 解析报错。
        let probeText = await client.probeEndpoints()
        guard client.isEndpointReady else {
            gatewayStatusText = probeText
            isLoading = false
            return
        }
        do {
            let remote = try await client.listCronTasks()
            mergeRemote(remote)
            gatewayStatusText = "已同步 \(remote.count) 个网关任务（端点：\(client.resolvedEndpoint == .restList ? "/cron/list" : "/cron/tasks")）"
        } catch {
            errorMessage = Self.errorText(error)
            gatewayStatusText = "网关同步失败，仅显示本机任务"
        }
        isLoading = false
    }

    /// 合并网关任务：网关有 id 的覆盖本机；本机独有（未同步）的保留。
    private func mergeRemote(_ remote: [AutomationTask]) {
        for var remoteTask in remote {
            // 网关拉回来的任务视为已同步
            remoteTask.gatewaySync = .synced
            if let index = tasks.firstIndex(where: { $0.id == remoteTask.id }) {
                tasks[index] = remoteTask
            } else {
                tasks.append(remoteTask)
            }
        }
        persist()
    }

    // MARK: - 网关写入（端点接线前仅记录日志）

    private func pushCreate(_ task: AutomationTask) async {
        guard let client = gatewayClient else { return }
        do {
            _ = try await client.createCronTask(task)
            markGatewaySync(taskID: task.id, state: .synced)
            gatewayStatusText = "已同步到网关"
        } catch {
            markGatewaySync(taskID: task.id, state: .failed)
            gatewayStatusText = "网关未同步：\(Self.errorText(error))"
        }
    }

    private func pushUpdate(_ task: AutomationTask) async {
        guard let client = gatewayClient else { return }
        do {
            _ = try await client.updateCronTask(task)
            markGatewaySync(taskID: task.id, state: .synced)
            gatewayStatusText = "已同步到网关"
        } catch {
            markGatewaySync(taskID: task.id, state: .failed)
            gatewayStatusText = "网关未同步：\(Self.errorText(error))"
        }
    }

    private func pushDelete(id: String) async {
        guard let client = gatewayClient else { return }
        do {
            try await client.deleteCronTask(id: id)
            gatewayStatusText = "已从网关删除任务"
        } catch {
            gatewayStatusText = "网关未同步：删除失败（\(Self.errorText(error))）"
        }
    }

    private func pushEnabledChange(id: String, enabled: Bool) async {
        guard let client = gatewayClient else { return }
        do {
            try await client.setCronTaskEnabled(id: id, enabled: enabled)
            markGatewaySync(taskID: id, state: .synced)
            gatewayStatusText = "已同步到网关"
        } catch {
            markGatewaySync(taskID: id, state: .failed)
            gatewayStatusText = "网关未同步：\(Self.errorText(error))"
        }
    }

    /// 回写任务网关同步状态并持久化（列表角标「网关未同步」的数据源）。
    private func markGatewaySync(taskID: String, state: GatewaySyncState) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].gatewaySync = state
        persist()
    }

    private static func errorText(_ error: Error) -> String {
        AppErrorText.localized(error.localizedDescription)
    }

    // MARK: - 本地持久化

    private func loadLocalData() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([AutomationTask].self, from: data) {
            tasks = decoded
        }
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([String: [AutomationRunResult]].self, from: data) {
            runHistories = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        if let data = try? JSONEncoder().encode(runHistories) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}
