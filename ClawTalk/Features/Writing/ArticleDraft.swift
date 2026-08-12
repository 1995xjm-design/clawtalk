import Foundation

/// 文章语气：正式 / 轻松 / 专业 / 感人。
enum ArticleTone: String, Codable, CaseIterable, Identifiable {
    case formal = "正式"
    case casual = "轻松"
    case professional = "专业"
    case touching = "感人"

    var id: String { rawValue }

    /// 给 AI 提示词用的语气描述（比单字更明确）。
    var promptDescription: String {
        switch self {
        case .formal: return "正式书面语，用词严谨，句式完整"
        case .casual: return "轻松口语化，像朋友聊天，读起来亲切"
        case .professional: return "专业客观，逻辑清晰，用词准确"
        case .touching: return "温暖感人，有画面感和情绪共鸣"
        }
    }
}

/// 一篇「语音写文章」草稿。
///
/// 诚实约定：
/// - `generatedByAI == false` 表示本次是本地规则降级生成（未接 AI / AI 调用失败），
///   列表与详情都会显示「本地生成（未接 AI）」标注，绝不冒充 AI 生成结果；
/// - `outline` 保留口述要点原文（生成过程不删除、不篡改原始要点）；
/// - `wordCount` 为正文字符数（中文场景按字符计），编辑后由详情页刷新。
struct ArticleDraft: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    /// 口述要点（可空：纯手动输入要点的场景）
    var outline: [String]?
    var tone: ArticleTone
    var wordCount: Int?
    let createdAt: Date
    var updatedAt: Date
    /// true = AI 生成；false = 本地规则降级（UI 诚实标注）
    var generatedByAI: Bool
    /// 生成说明（降级原因 / AI 结构说明，展示给用户，诚实不编造）
    var generationNotice: String?

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        outline: [String]? = nil,
        tone: ArticleTone = .formal,
        wordCount: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        generatedByAI: Bool,
        generationNotice: String? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.outline = outline
        self.tone = tone
        self.wordCount = wordCount ?? content.count
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.generatedByAI = generatedByAI
        self.generationNotice = generationNotice
    }

    /// 容错解码：旧数据缺新增字段时用默认值，不因升级导致已有文章读不出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        outline = try container.decodeIfPresent([String].self, forKey: .outline)
        tone = try container.decodeIfPresent(ArticleTone.self, forKey: .tone) ?? .formal
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        generatedByAI = try container.decodeIfPresent(Bool.self, forKey: .generatedByAI) ?? false
        generationNotice = try container.decodeIfPresent(String.self, forKey: .generationNotice)
    }

    var isLocalFallback: Bool {
        !generatedByAI
    }

    /// 生成来源展示文案：本地降级时诚实标注「本地生成（未接 AI）」。
    var generationLabel: String {
        generatedByAI ? "AI 生成" : "本地生成（未接 AI）"
    }

    /// 字数展示（正文字符数）。
    var wordCountText: String {
        guard let wordCount else { return "" }
        return "\(wordCount) 字"
    }

    /// 正文段落数（列表摘要用；按空行粗分）。
    var paragraphCount: Int {
        let paragraphs = content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return max(paragraphs.count, content.isEmpty ? 0 : 1)
    }
}
