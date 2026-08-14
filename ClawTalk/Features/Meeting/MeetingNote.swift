import Foundation

/// 会议纪要里的一条待办。
/// - assignee / dueDate 可空：AI 或本地规则没识别出来就不编造，保持诚实。
struct ActionItem: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    /// 负责人（不确定时为 nil）
    var assignee: String?
    /// 截止时间（不确定时为 nil）
    var dueDate: Date?

    init(id: UUID = UUID(), text: String, assignee: String? = nil, dueDate: Date? = nil) {
        self.id = id
        self.text = text
        self.assignee = assignee
        self.dueDate = dueDate
    }
}

/// 一份结构化会议纪要。
///
/// 诚实约定：
/// - `organizedByAI == false` 表示本次是本地规则降级整理（未接 AI / AI 失败），
///   列表与详情都会显示「本地整理（未接 AI）」标注，绝不冒充 AI 整理结果；
/// - `rawTranscript` 保留原始转写全文，整理过程不删除、不篡改原始内容；
/// - `linkedReminderIDs` 记录已一键加入提醒的待办，避免重复添加。
struct MeetingNote: Identifiable, Codable, Equatable {
    let id: UUID
    /// 会议发生日期（= 录音日期）
    var date: Date
    var title: String
    var participants: [String]
    var topics: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var summary: String
    /// 原始转写全文
    var rawTranscript: String
    /// 录音存档文件名（保存在 Application Support/ClawTalk/MeetingAudio，可回放；nil = 无录音）
    var audioFileName: String?
    let createdAt: Date
    /// true = AI 整理；false = 本地规则降级（UI 诚实标注）
    var organizedByAI: Bool
    /// 已加入提醒的待办 id（ActionItem.id.uuidString）
    var linkedReminderIDs: [String]

    init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        participants: [String] = [],
        topics: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        summary: String,
        rawTranscript: String,
        audioFileName: String? = nil,
        createdAt: Date = Date(),
        organizedByAI: Bool,
        linkedReminderIDs: [String] = []
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.participants = participants
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.summary = summary
        self.rawTranscript = rawTranscript
        self.audioFileName = audioFileName
        self.createdAt = createdAt
        self.organizedByAI = organizedByAI
        self.linkedReminderIDs = linkedReminderIDs
    }

    /// 整理来源展示文案：本地降级时诚实标注「本地整理（未接 AI）」。
    var organizationLabel: String {
        organizedByAI ? "AI 整理" : "本地整理（未接 AI）"
    }

    /// 某条待办是否已加入提醒。
    func hasLinkedReminder(for actionID: UUID) -> Bool {
        linkedReminderIDs.contains(actionID.uuidString)
    }

    /// 容错解码：旧数据缺字段（如 organizedByAI / linkedReminderIDs）时用默认值，
    /// 不因新字段导致老纪要读不出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        title = try container.decode(String.self, forKey: .title)
        participants = try container.decodeIfPresent([String].self, forKey: .participants) ?? []
        topics = try container.decodeIfPresent([String].self, forKey: .topics) ?? []
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript) ?? ""
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? date
        organizedByAI = try container.decodeIfPresent(Bool.self, forKey: .organizedByAI) ?? false
        linkedReminderIDs = try container.decodeIfPresent([String].self, forKey: .linkedReminderIDs) ?? []
    }
}