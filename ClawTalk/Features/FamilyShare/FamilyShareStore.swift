import Foundation
import Observation

/// 家庭共享提醒存储：本地持久化（App Group: group.7518554）+ 通过网关共享给家人 + 接收家人提醒。
///
/// 发送（共享给家人）：
/// - share(careReminder:assignee:) 先把提醒转成 FamilyReminder 落本地（状态「待确认」、synced=false），
///   再异步调 OpenClawClient.invokeTool 让网关 agent 把提醒转发给家人（内容自包含：标题+时间+负责人）。
/// - 网关失败不阻塞本地：列表标「未同步」，提供重试；网关未配置时静默跳过
///   （与 MemoryProfileStore.syncToGateway 同款诚实策略）。
/// - 工具名/参数为假设（family_reminder.send），待网关侧确认。
///
/// 接收（家人发来的提醒）：
/// - readInbox() 读取 App Group 共享区的待收键（flag + JSON 数据，与 ClawTalkShareExtension 的
///   pending_share_message 契约同款结构），导入为「待确认」提醒后清标记。
/// - pullFromGateway() 为网关拉取预留（端点待网关侧确认），未确认前不发起调用、不造假数据。
@Observable
@MainActor
final class FamilyShareStore {

    private(set) var reminders: [FamilyReminder] = []

    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "家庭共享提醒", errorMessage)
            }
        }
    }

    // MARK: - 键与 App Group 契约

    /// 本地列表存储键（App Group suite，与收件箱同一命名空间）。
    private let storageKey = "clawtalk_family_reminders_v1"

    /// App Group 共享区：与 ClawTalkApp.swift 的分享扩展轮询同款（group.7518554）。
    /// 待收提醒键名/格式对齐 pending_share_message 契约（flag + JSON 数据）；
    /// 写入方待确认（预期：网关同步桥或未来家人端推送后落盘）。
    private static let appGroupSuite = "group.7518554"
    private static let inboxFlagKey = "pending_family_reminder_flag"
    private static let inboxDataKey = "pending_family_reminder"

    private let settings: SettingsStore?
    private let client = OpenClawClient()

    init(settings: SettingsStore? = nil) {
        self.settings = settings
        load()
    }

    // MARK: - 查询

    /// 待确认数量（主页卡片角标）。
    var pendingCount: Int {
        reminders.filter { $0.status == .pending }.count
    }

    /// 家人发来的提醒（按时间升序）。
    var receivedReminders: [FamilyReminder] {
        reminders.filter { $0.direction == .received }.sorted { $0.time < $1.time }
    }

    /// 我共享出去的提醒（按时间升序）。
    var sentReminders: [FamilyReminder] {
        reminders.filter { $0.direction == .sent }.sorted { $0.time < $1.time }
    }

    // MARK: - 发送（共享给家人）

    /// 把一条现有 CareReminder 转成家庭共享提醒并发送。
    /// - 转换时 time 取 scheduledDate ?? time，保留一次性提醒的完整日期；
    /// - 先落本地再异步走网关，失败不阻塞，状态保持「未同步」。
    @discardableResult
    func share(careReminder: CareReminder, assignee: String) -> FamilyReminder {
        let trimmedAssignee = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        let reminder = FamilyReminder(
            title: careReminder.title,
            time: careReminder.scheduledDate ?? careReminder.time,
            assignee: trimmedAssignee.isEmpty ? "家人" : trimmedAssignee,
            direction: .sent,
            synced: false
        )
        reminders.append(reminder)
        persist()
        Task { await syncToGateway(reminder) }
        return reminder
    }

    /// 重试未同步的共享提醒（列表「未同步」行的重试按钮）。
    func retrySync(id: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }), !reminders[index].synced else { return }
        Task { await syncToGateway(reminders[index]) }
    }

    /// 网关共享：通过 invokeTool 让 agent 把提醒转发给家人。
    /// 工具名与参数为假设（family_reminder.send），待网关侧确认；
    /// 内容自包含（标题+时间+负责人），方便网关按文本转发。
    private func syncToGateway(_ reminder: FamilyReminder) async {
        guard let settings, settings.isConfigured else { return }
        let gatewayURL = settings.settings.gatewayURL
        let token = OpenClawClient.resolveHTTPToken(
            settingsToken: settings.gatewayToken,
            gatewayURL: gatewayURL
        )
        do {
            _ = try await client.invokeTool(
                tool: "family_reminder.send",
                args: [
                    "reminderId": .string(reminder.id),
                    "title": .string(reminder.title),
                    "time": .string(reminder.time.ISO8601Format()),
                    "assignee": .string(reminder.assignee),
                    "sharedAt": .string(reminder.sharedAt.ISO8601Format())
                ],
                gatewayURL: gatewayURL,
                token: token
            )
            markSynced(id: reminder.id)
        } catch {
            // 网关未部署/参数不符/网络失败：本地保留，状态保持「未同步」，可重试
        }
    }

    private func markSynced(id: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].synced = true
        persist()
    }

    // MARK: - 接收（家人发来的提醒）

    /// 读取 App Group 共享区的待收提醒并导入（幂等：重复 id 直接清标记跳过）。
    /// 没有待收数据时静默返回，不造假。
    func readInbox() {
        guard let groupDefaults = UserDefaults(suiteName: Self.appGroupSuite),
              groupDefaults.bool(forKey: Self.inboxFlagKey),
              let data = groupDefaults.data(forKey: Self.inboxDataKey),
              let pending = try? JSONDecoder().decode(PendingFamilyReminder.self, from: data)
        else { return }

        let reminder = pending.toFamilyReminder()
        if !reminders.contains(where: { $0.id == reminder.id }) {
            reminders.append(reminder)
            persist()
        }
        clearInbox(groupDefaults)
    }

    private func clearInbox(_ groupDefaults: UserDefaults) {
        groupDefaults.set(false, forKey: Self.inboxFlagKey)
        groupDefaults.synchronize()
    }

    /// 网关拉取（预留）：从网关拉家人发来的提醒。
    /// 端点/工具名待网关侧确认，确认前不发起调用、返回空数组；
    /// 接入后把拉到的数据转成 FamilyReminder（direction: .received）导入。
    func pullFromGateway() async -> [FamilyReminder] {
        []
    }

    // MARK: - 状态流转

    /// 确认家人发来的提醒（本地先行；回写网关端点待网关侧确认）。
    func confirm(id: String) {
        setStatus(.confirmed, for: id)
    }

    /// 标记完成（本地先行；回写网关端点待网关侧确认）。
    func complete(id: String) {
        setStatus(.completed, for: id)
    }

    private func setStatus(_ status: FamilyReminderStatus, for id: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].status = status
        persist()
    }

    func delete(id: String) {
        reminders.removeAll { $0.id == id }
        persist()
    }

    // MARK: - 本地持久化（App Group suite）

    private func load() {
        guard let data = UserDefaults(suiteName: Self.appGroupSuite)?.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FamilyReminder].self, from: data)
        else {
            reminders = []
            return
        }
        reminders = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(reminders),
              let groupDefaults = UserDefaults(suiteName: Self.appGroupSuite)
        else { return }
        groupDefaults.set(data, forKey: storageKey)
        groupDefaults.synchronize()
    }

    // MARK: - 收件箱契约（对齐 pending_share_message 格式）

    /// 家人端写入 App Group 的待收提醒（flag + JSON 数据，与 PendingShareMessage 同款结构：
    /// createdAt 等时间字段用 TimeInterval）。写入方待网关侧确认；主 App 只读不改写字段。
    struct PendingFamilyReminder: Codable {
        var id: String
        var title: String
        var time: TimeInterval
        var assignee: String
        var sharedAt: TimeInterval
        var createdAt: TimeInterval

        func toFamilyReminder() -> FamilyReminder {
            FamilyReminder(
                id: id,
                title: title,
                time: Date(timeIntervalSince1970: time),
                assignee: assignee,
                status: .pending,
                direction: .received,
                sharedAt: Date(timeIntervalSince1970: sharedAt),
                createdAt: Date(timeIntervalSince1970: createdAt),
                synced: true
            )
        }
    }
}
