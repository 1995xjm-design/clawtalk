import Foundation

/// 语音日记条目类别。
/// 由转写文本按简单规则自动归类：待办（明确提醒/待办意图）/ 灵感（灵感信号）/ 其余为日记。
enum DiaryCategory: String, Codable, CaseIterable, Identifiable, Equatable {
    case diary = "日记"
    case todo = "待办"
    case inspiration = "灵感"

    var id: String { rawValue }

    /// 按简单规则为转写文本分类（后续可替换为网关/LLM 语义分类，规则点集中在此处）。
    ///
    /// 优先级：待办 > 灵感 > 日记。
    /// - 待办：含明确提醒/待办意图的祈使词（提醒我/记得/别忘了/要记得/帮我设…）。
    ///   时间词本身不再是待办信号——「明天要去爬山」只是日常叙述，归日记；
    ///   「明天下午3点提醒我开会」含祈使词，才归待办。
    /// - 灵感：含「灵感/想法/点子/我想/主意/创意」。
    /// - 其他（含时间词的日常叙述）：日记。
    ///
    /// 已知粗规则局限（简单规则可接受，后续换 LLM 精化）：
    /// - 「我记得……」是叙述，但「记得」一词会误判为待办。
    /// - 「我想……」统一归灵感（按需求清单，不区分「我想起/我想去」）。
    static func classify(_ text: String) -> DiaryCategory {
        let todoKeywords = [
            "提醒我", "提醒一下", "记得", "别忘了", "别忘", "要记得",
            "帮我设", "帮我设置", "帮我定", "设个提醒", "设置提醒", "设提醒",
            "定个提醒", "安排个提醒", "安排提醒"
        ]
        if todoKeywords.contains(where: { text.contains($0) }) {
            return .todo
        }

        let inspirationKeywords = ["灵感", "想法", "点子", "我想", "主意", "创意"]
        if inspirationKeywords.contains(where: { text.contains($0) }) {
            return .inspiration
        }

        return .diary
    }
}

/// 一条语音日记（本地暂存；待办/灵感可联动写入提醒与记忆中心，状态见 linkedReminderID / linkedToMemory）。
struct DiaryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    /// 录音日期（按日分组用，取录音开始时间）
    let date: Date
    /// 转写后的正文
    let text: String
    /// 自动分类：日记 / 待办 / 灵感
    let category: DiaryCategory
    /// 条目创建时间（预留：后续编辑/迁移时保留原始时间戳）
    let createdAt: Date
    /// 待办联动：已写入 CareReminderStore 的提醒 id（nil = 未联动）。
    /// 可选字段：老数据解码缺省为 nil，兼容已有本地暂存。
    var linkedReminderID: String?
    /// 灵感联动：是否已作为档案条目写入 MemoryProfileStore（nil/缺省 = 未沉淀）。
    var linkedToMemory: Bool?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        category: DiaryCategory,
        createdAt: Date = Date(),
        linkedReminderID: String? = nil,
        linkedToMemory: Bool? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.category = category
        self.createdAt = createdAt
        self.linkedReminderID = linkedReminderID
        self.linkedToMemory = linkedToMemory
    }
}
