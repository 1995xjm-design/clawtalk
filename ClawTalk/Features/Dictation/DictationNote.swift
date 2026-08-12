import Foundation

/// 一份口述整理文档。
///
/// 诚实约定：
/// - `organizedByAI == false` 表示本次是本地规则降级整理（未接 AI / AI 失败），
///   列表与详情都会显示「本地整理（未接 AI）」标注，绝不冒充 AI 整理结果；
/// - `rawTranscript` 保留原始转写全文，整理过程不删除、不篡改原始内容；
/// - `content` 为整理后的正文（paragraphs 按空行拼接），详情页按 paragraphs 分段展示。
struct DictationNote: Identifiable, Codable, Equatable {
    let id: UUID
    /// 口述日期（= 录音日期）
    var date: Date
    var title: String
    /// 整理后的正文（paragraphs 的纯文本拼接，导出/分享用）
    var content: String
    /// 分段（按逻辑段落拆分，按顺序展示）
    var paragraphs: [String]
    /// 要点（AI 或本地规则提取；没有就不编造，保持空数组）
    var keyPoints: [String]
    let createdAt: Date
    /// true = AI 整理；false = 本地规则降级（UI 诚实标注）
    var organizedByAI: Bool
    /// 原始转写全文
    var rawTranscript: String

    init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        content: String,
        paragraphs: [String],
        keyPoints: [String] = [],
        createdAt: Date = Date(),
        organizedByAI: Bool,
        rawTranscript: String
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.content = content
        self.paragraphs = paragraphs
        self.keyPoints = keyPoints
        self.createdAt = createdAt
        self.organizedByAI = organizedByAI
        self.rawTranscript = rawTranscript
    }

    /// 整理来源展示文案：本地降级时诚实标注「本地整理（未接 AI）」。
    var organizationLabel: String {
        organizedByAI ? "AI 整理" : "本地整理（未接 AI）"
    }

    /// 段落数（列表/卡片摘要用）。
    var paragraphCount: Int {
        paragraphs.count
    }

    /// 容错解码：旧数据缺字段（organizedByAI / rawTranscript 等）时用默认值，
    /// 不因新增字段导致老文档读不出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        paragraphs = try container.decodeIfPresent([String].self, forKey: .paragraphs) ?? []
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? date
        organizedByAI = try container.decodeIfPresent(Bool.self, forKey: .organizedByAI) ?? false
        rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript) ?? ""
    }
}
