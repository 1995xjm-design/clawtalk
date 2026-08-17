import Foundation

// 官方 OpenClaw Gateway Question（提问/回答）协议模型。
// 对齐 OpenClawKit GatewayModels.swift（question.requested / question.resolved /
// question.list / question.get / question.resolve），保证与官方网关互通。

public enum QuestionStatus: String, Codable, Sendable {
    case pending = "pending"
    case answered = "answered"
    case cancelled = "cancelled"
    case expired = "expired"
}

public struct QuestionOption: Codable, Sendable, Hashable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct Question: Codable, Sendable, Identifiable, Hashable {
    public let questionId: String
    public let header: String
    public let question: String
    public let options: [QuestionOption]
    public let multiSelect: Bool?
    public let isOther: Bool?
    public let isSecret: Bool?

    public var id: String { questionId }

    public init(
        questionId: String,
        header: String,
        question: String,
        options: [QuestionOption],
        multiSelect: Bool? = nil,
        isOther: Bool? = nil,
        isSecret: Bool? = nil)
    {
        self.questionId = questionId
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.isOther = isOther
        self.isSecret = isSecret
    }

    private enum CodingKeys: String, CodingKey {
        case questionId = "questionId"
        case header
        case question
        case options
        case multiSelect = "multiSelect"
        case isOther = "isOther"
        case isSecret = "isSecret"
    }
}

public struct QuestionAnswers: Codable, Sendable {
    public let answers: [String: [String]]

    public init(answers: [String: [String]]) {
        self.answers = answers
    }
}

public struct QuestionRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let questions: [Question]
    public let agentId: String?
    public let sessionKey: String?
    public let runId: String?
    public let createdAtMs: Int
    public let expiresAtMs: Int
    public let status: QuestionStatus
    public let answers: QuestionAnswers?
    public let resolvedBy: String?

    public var isPending: Bool { status == .pending }

    public var expiresAt: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000)
    }

    public init(
        id: String,
        questions: [Question],
        agentId: String? = nil,
        sessionKey: String? = nil,
        runId: String? = nil,
        createdAtMs: Int,
        expiresAtMs: Int,
        status: QuestionStatus,
        answers: QuestionAnswers? = nil,
        resolvedBy: String? = nil)
    {
        self.id = id
        self.questions = questions
        self.agentId = agentId
        self.sessionKey = sessionKey
        self.runId = runId
        self.createdAtMs = createdAtMs
        self.expiresAtMs = expiresAtMs
        self.status = status
        self.answers = answers
        self.resolvedBy = resolvedBy
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case questions
        case agentId = "agentId"
        case sessionKey = "sessionKey"
        case runId = "runId"
        case createdAtMs = "createdAtMs"
        case expiresAtMs = "expiresAtMs"
        case status
        case answers
        case resolvedBy = "resolvedBy"
    }
}

/// question.resolved 事件载荷。
/// question.list result.
public struct QuestionListResult: Codable, Sendable {
    public let questions: [QuestionRecord]

    public init(questions: [QuestionRecord]) {
        self.questions = questions
    }
}

/// question.get result.
public struct QuestionGetResult: Codable, Sendable {
    public let question: QuestionRecord

    public init(question: QuestionRecord) {
        self.question = question
    }
}

public struct OpenClawQuestionResolvedEvent: Codable, Sendable {
    public let id: String
    public let status: QuestionStatus
    public let answers: QuestionAnswers?

    public init(id: String, status: QuestionStatus, answers: QuestionAnswers? = nil) {
        self.id = id
        self.status = status
        self.answers = answers
    }
}
