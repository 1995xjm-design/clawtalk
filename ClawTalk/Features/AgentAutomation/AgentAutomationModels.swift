import Foundation

/// 自动化模型（对齐官方 AgentAutomationModels）：
/// 草稿（计划/载荷）、运行结果、pending run 注册表。
struct AgentAutomationScheduleDraft: Equatable {
    var expression: String?
    var timezone: String?
    var startDate: String?
    var endDate: String?

    static func == (lhs: AgentAutomationScheduleDraft, rhs: AgentAutomationScheduleDraft) -> Bool {
        lhs.expression == rhs.expression && lhs.timezone == rhs.timezone
    }
}

enum AgentAutomationValue: Equatable {
    case string(String)
    case int(Int)
    case strings([String])

    static func object(_ value: Any?) -> AgentAutomationValue? {
        if let string = value as? String { return .string(string) }
        if let int = value as? Int { return .int(int) }
        if let strings = value as? [String] { return .strings(strings) }
        return nil
    }

    var rawValue: Any? {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .strings(let value): return value
        }
    }
}

struct AgentAutomationPayloadDraft: Equatable {
    var action: String?
    var parameters: [String: AgentAutomationValue]

    static func == (lhs: AgentAutomationPayloadDraft, rhs: AgentAutomationPayloadDraft) -> Bool {
        lhs.action == rhs.action
    }
}

struct AgentAutomationDraft: Identifiable, Equatable {
    var id: String
    var name: String?
    var enabled: Bool
    var schedule: AgentAutomationScheduleDraft
    var payload: AgentAutomationPayloadDraft
}

struct AgentAutomationRunsResponse: Codable {
    var runs: [AgentAutomationRunResult]?
    var total: Int?
    var ok: Bool?
}

struct AgentAutomationRunResult: Codable, Identifiable {
    var runID: String?
    var taskID: String?
    var status: String?
    var startedAt: String?
    var endedAt: String?
    var error: String?
    var summary: String?

    var id: String { runID ?? taskID ?? UUID().uuidString }
}

enum AgentAutomationRunOutcome {
    case succeeded
    case failed(String?)
    case cancelled

    init(status: String?, error: String?) {
        switch status {
        case "completed", "succeeded": self = .succeeded
        case "cancelled", "cancelled_by_user": self = .cancelled
        default: self = .failed(error)
        }
    }
}

/// pending run 注册表：保留已派发但未确认的 run id，避免重复派发。
@MainActor
final class AgentAutomationPendingRunRegistry {
    private var pending = Set<String>()

    func reserve(_ runID: String) -> Bool {
        guard !pending.contains(runID) else { return false }
        pending.insert(runID)
        return true
    }

    func release(_ runID: String) {
        pending.remove(runID)
    }

    var count: Int { pending.count }
}

enum AgentAutomationEditError: LocalizedError {
    case emptyName
    case invalidExpression

    var errorDescription: String? {
        switch self {
        case .emptyName: return "任务名称不能为空"
        case .invalidExpression: return "调度表达式无效"
        }
    }
}
