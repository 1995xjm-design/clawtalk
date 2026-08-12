import Foundation

/// 知识库问答状态：诚实区分答案来源，不编造。
/// - memory: 纯检索拼接（来自记忆库片段）
/// - agent: 智能体基于记忆库资料回答
/// - noResult: 检索无结果（如实提示）
/// - error: 网关/检索失败（如实提示）
enum KBAnswerKind: String, Codable, Sendable {
    case memory
    case agent
    case noResult
    case error

    /// 界面徽标文案。
    var displayName: String {
        switch self {
        case .memory: return "来自记忆库"
        case .agent: return "智能体回答"
        case .noResult: return "无匹配"
        case .error: return "失败"
        }
    }
}

/// 一次问答的结果（供 UI 展示与历史记录）。
struct KBAnswer: Equatable, Sendable {
    let text: String
    let sources: [String]
    let kind: KBAnswerKind
}

/// 问答记录：id / 问题 / 答案 / 来源路径列表 / 提问时间。
struct KBQuestion: Identifiable, Codable, Hashable {
    let id: UUID
    let question: String
    let answer: String
    let sources: [String]
    let askedAt: Date
    let kind: KBAnswerKind

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        sources: [String],
        askedAt: Date = Date(),
        kind: KBAnswerKind = .memory
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.sources = sources
        self.askedAt = askedAt
        self.kind = kind
    }
}
