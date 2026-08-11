import Foundation

/// 语音日记条目类别。
/// 由转写文本按简单规则自动归类：待办（含时间词）/ 灵感（含灵感词）/ 其余为日记。
enum DiaryCategory: String, Codable, CaseIterable, Identifiable, Equatable {
    case diary = "日记"
    case todo = "待办"
    case inspiration = "灵感"

    var id: String { rawValue }

    /// 按简单规则为转写文本分类（后续可替换为网关/LLM 语义分类，规则点集中在此处）。
    /// - 待办：包含明确时间词（明天/今晚/下午/3点/周X/15:00 等）
    /// - 灵感：包含「灵感/想法/点子/我想/主意/创意」
    /// - 其他：日记
    static func classify(_ text: String) -> DiaryCategory {
        let todoKeywords = [
            "明天", "后天", "今天", "明早", "明晚", "今晚",
            "凌晨", "上午", "中午", "下午", "晚上", "几点", "点钟"
        ]
        if todoKeywords.contains(where: { text.contains($0) }) {
            return .todo
        }
        // 周X / 星期X
        if text.range(of: #"(周|星期)[一二三四五六日天]"#, options: .regularExpression) != nil {
            return .todo
        }
        // 3点 / 下午3点 等
        if text.range(of: #"\d{1,2}\s*点"#, options: .regularExpression) != nil {
            return .todo
        }
        // 15:00 / 15：00
        if text.range(of: #"\d{1,2}[:：]\d{2}"#, options: .regularExpression) != nil {
            return .todo
        }

        let inspirationKeywords = ["灵感", "想法", "点子", "我想", "主意", "创意"]
        if inspirationKeywords.contains(where: { text.contains($0) }) {
            return .inspiration
        }

        return .diary
    }
}

/// 一条语音日记（本地暂存，尚未写入记忆中心）。
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

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        category: DiaryCategory,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.category = category
        self.createdAt = createdAt
    }
}
