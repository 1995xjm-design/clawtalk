import Foundation

/// 主动建议类型：健康 / 理财 / 习惯 / 记忆 / 效率。
enum SuggestionType: String, Codable, CaseIterable, Identifiable, Equatable {
    case health = "健康"
    case finance = "理财"
    case habit = "习惯"
    case memory = "记忆"
    case efficiency = "效率"

    var id: String { rawValue }

    /// SF Symbol 名称（列表行 / 主页卡片图标）。
    var systemImage: String {
        switch self {
        case .health: return "heart.fill"
        case .finance: return "yensign.circle.fill"
        case .habit: return "checkmark.seal.fill"
        case .memory: return "lightbulb.fill"
        case .efficiency: return "clock.fill"
        }
    }
}

/// 建议优先级：高 / 中 / 低。
enum SuggestionPriority: String, Codable, CaseIterable, Identifiable, Equatable {
    case high = "high"
    case medium = "medium"
    case low = "low"

    var id: String { rawValue }

    /// 展示用中文（列表优先级角标）。
    var displayName: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    /// 排序权重：高 -> 中 -> 低。
    var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

/// 一条主动建议：由 SuggestionEngine 依据真实本地数据生成，不编造。
///
/// 诚实原则：
/// - 只在数据充分时生成（如健康权限未开、本周无记账记录，则对应类型不产出建议）；
/// - `action` 只是提示语（如「去打卡」），不做假跳转；
/// - 列表只保留未读建议；已读 / 忽略即移出。
struct Suggestion: Identifiable, Codable, Equatable {
    let id: UUID
    let type: SuggestionType
    let priority: SuggestionPriority
    let title: String
    let body: String
    /// 可执行提示（如「去打卡」「去健康」；纯提示文案，不做假导航）
    var action: [String]?
    let createdAt: Date
    /// 是否已读（列表只保留未读；已读条目标记后即移出存储）
    var read: Bool

    init(
        id: UUID = UUID(),
        type: SuggestionType,
        priority: SuggestionPriority,
        title: String,
        body: String,
        action: [String]? = nil,
        createdAt: Date = Date(),
        read: Bool = false
    ) {
        self.id = id
        self.type = type
        self.priority = priority
        self.title = title
        self.body = body
        self.action = action
        self.createdAt = createdAt
        self.read = read
    }

    /// 去重键：同类型 + 同标题 + 同正文视为同一条建议（重复生成时保留最早一条）。
    var dedupeKey: String {
        "\(type.rawValue)|\(title)|\(body)"
    }
}
