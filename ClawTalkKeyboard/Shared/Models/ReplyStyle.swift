import Foundation

// MARK: - 回复风格
enum ReplyStyle: String, Codable, CaseIterable {
    case sweet = "撒娇"
    case gentle = "温柔"
    case domineering = "霸道"
    case humorous = "幽默"
    case romantic = "浪漫"
    case caring = "关心"
    case flirty = "调情"
    case sincere = "真诚"

    var description: String {
        switch self {
        case .sweet: return "可爱撒娇风格"
        case .gentle: return "温柔体贴风格"
        case .domineering: return "霸道总裁风格"
        case .humorous: return "风趣幽默风格"
        case .romantic: return "浪漫甜蜜风格"
        case .caring: return "关心呵护风格"
        case .flirty: return "轻松调情风格"
        case .sincere: return "真诚坦率风格"
        }
    }

    var promptPrefix: String {
        switch self {
        case .sweet: return "用撒娇可爱的语气"
        case .gentle: return "用温柔体贴的语气"
        case .domineering: return "用霸道自信的语气"
        case .humorous: return "用幽默风趣的语气"
        case .romantic: return "用浪漫甜蜜的语气"
        case .caring: return "用关心呵护的语气"
        case .flirty: return "用轻松调情的语气"
        case .sincere: return "用真诚坦率的语气"
        }
    }
}

// MARK: - 身份类型（超会说用）
enum IdentityType: String, Codable, CaseIterable {
    case general = "通用"
    case boyfriend = "男朋友"
    case girlfriend = "女朋友"
    case crush = "心动对象"
    case wife = "妻子"
    case husband = "丈夫"
    case bestie = "闺蜜"
    case friend = "朋友"
    case boss = "上司"
    case client = "客户"
    case colleague = "同事"
    case family = "家人"

    var displayName: String {
        return self.rawValue
    }
}

// MARK: - 回复数据
struct ReplyItem: Identifiable {
    let id = UUID()
    let text: String
    let style: ReplyStyle?

    init(text: String, style: ReplyStyle? = nil) {
        self.text = text
        self.style = style
    }
}

// MARK: - 润色结果
struct PolishResult: Identifiable {
    let id = UUID()
    let styleName: String
    let text: String
}
