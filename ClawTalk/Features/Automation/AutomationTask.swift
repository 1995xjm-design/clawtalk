import Foundation

/// 自动化任务模型（本机 + 网关 cron 同步共用）。
/// - cronExpression：5 字段 cron（分 时 日 月 周），如 "0 9 * * 1-5" = 每工作日 09:00
/// - nextRunAt：下次执行时间，由网关排程后回填；接线前为 nil（列表显示「待网关排程」，不造假）
struct AutomationTask: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var cronExpression: String
    /// 任务描述 / 交代给智能体执行的内容
    var description: String
    var enabled: Bool
    var lastRunAt: Date?
    var lastResult: AutomationRunResult?
    var nextRunAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String,
        cronExpression: String,
        description: String = "",
        enabled: Bool = true,
        lastRunAt: Date? = nil,
        lastResult: AutomationRunResult? = nil,
        nextRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.cronExpression = cronExpression
        self.description = description
        self.enabled = enabled
        self.lastRunAt = lastRunAt
        self.lastResult = lastResult
        self.nextRunAt = nextRunAt
    }
}

/// 单次运行结果摘要（网关执行后回传；本地保留最近若干条用于「历史」入口）
struct AutomationRunResult: Codable, Equatable, Identifiable {
    var id: String { "\(runAt.timeIntervalSince1970)-\(succeeded)-\(summary)" }
    var runAt: Date
    var succeeded: Bool
    var summary: String

    init(runAt: Date = Date(), succeeded: Bool, summary: String) {
        self.runAt = runAt
        self.succeeded = succeeded
        self.summary = summary
    }
}

extension AutomationTask {
    /// cron 的人类可读描述；解析不了时回退显示原始 cron。
    var scheduleDescription: String {
        CronParser.describe(cron: cronExpression) ?? cronExpression
    }
}
