import Foundation

/// 摘要来源：粘贴 / 分享 / 口述 / 手动输入。
enum SummarySource: String, Codable, CaseIterable, Identifiable, Equatable {
    case paste
    case share
    case dictation
    case input

    var id: String { rawValue }

    /// 展示文案（记录页来源标签用）。
    var label: String {
        switch self {
        case .paste: return "粘贴"
        case .share: return "分享"
        case .dictation: return "口述"
        case .input: return "输入"
        }
    }
}

/// 摘要长度档位：短 / 中 / 长。
/// 每档同时给出「AI 提示词长度要求」与「本地降级目标字符数」，
/// 两条路共用同一档位语义，保证短/中/长观感一致。
enum SummaryLength: String, Codable, CaseIterable, Identifiable, Equatable {
    case short
    case medium
    case long

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: return "短"
        case .medium: return "中"
        case .long: return "长"
        }
    }

    /// AI 提示词里的长度要求。
    var aiDirective: String {
        switch self {
        case .short: return "摘要控制在 60 字以内，只保留最核心的一句话"
        case .medium: return "摘要控制在 150 字以内，覆盖主要信息"
        case .long: return "摘要控制在 300 字以内，尽量覆盖全文关键信息"
        }
    }

    /// 本地降级摘要目标长度（字符）。
    var localSummaryTarget: Int {
        switch self {
        case .short: return 60
        case .medium: return 150
        case .long: return 300
        }
    }

    /// 本地降级要点数量上限。
    var localKeyPointLimit: Int {
        switch self {
        case .short: return 3
        case .medium: return 5
        case .long: return 8
        }
    }
}

/// 一条摘要记录。
///
/// 诚实约定：
/// - `usedFallback == true` 表示本次是本地规则降级（未接 AI / AI 失败），
///   页面展示「本地摘要（未接 AI）」标注，绝不冒充 AI 结果；
/// - `originalText` 保留原始全文（超长时仍保留完整原文，不删内容）；
/// - `truncationNotice` 在原文超过 20000 字时记录截断提示（AI 路径只送前 8000 字）。
struct SummaryRecord: Identifiable, Codable, Equatable {
    let id: UUID
    /// 原始长文本全文
    var originalText: String
    /// 摘要正文
    var summary: String
    /// 要点列表（没有明确要点时保持空数组，不编造）
    var keyPoints: [String]
    /// 来源：粘贴 / 分享 / 口述 / 输入
    var source: SummarySource
    /// 长度档位：短 / 中 / 长
    var length: SummaryLength
    let createdAt: Date
    /// true = 本地规则降级；false = AI 生成
    var usedFallback: Bool
    /// 降级原因（UI 诚实标注用）
    var fallbackReason: String?
    /// 超长截断提示（原文 > 20000 字时记录）
    var truncationNotice: String?

    init(
        id: UUID = UUID(),
        originalText: String,
        summary: String,
        keyPoints: [String] = [],
        source: SummarySource,
        length: SummaryLength,
        createdAt: Date = Date(),
        usedFallback: Bool,
        fallbackReason: String? = nil,
        truncationNotice: String? = nil
    ) {
        self.id = id
        self.originalText = originalText
        self.summary = summary
        self.keyPoints = keyPoints
        self.source = source
        self.length = length
        self.createdAt = createdAt
        self.usedFallback = usedFallback
        self.fallbackReason = fallbackReason
        self.truncationNotice = truncationNotice
    }

    /// 摘要来源展示文案：本地降级时诚实标注「本地摘要（未接 AI）」。
    var summaryLabel: String {
        usedFallback ? "本地摘要（未接 AI）" : "AI 摘要"
    }

    /// 导出/分享的纯文本（摘要 + 要点 + 来源/长度/方式元信息）。
    var exportText: String {
        var lines = ["【长文摘要】", "", summary, ""]
        if !keyPoints.isEmpty {
            lines.append("【要点】")
            for point in keyPoints {
                lines.append("· \(point)")
            }
            lines.append("")
        }
        lines.append("来源：\(source.label) · 长度：\(length.label) · \(summaryLabel)")
        if let truncationNotice {
            lines.append(truncationNotice)
        }
        return lines.joined(separator: "\n")
    }

    /// 容错解码：旧数据缺字段时用默认值，不因新增字段导致历史记录读不出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        originalText = try container.decodeIfPresent(String.self, forKey: .originalText) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        source = try container.decodeIfPresent(SummarySource.self, forKey: .source) ?? .input
        length = try container.decodeIfPresent(SummaryLength.self, forKey: .length) ?? .medium
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        usedFallback = try container.decodeIfPresent(Bool.self, forKey: .usedFallback) ?? false
        fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
        truncationNotice = try container.decodeIfPresent(String.self, forKey: .truncationNotice)
    }
}
