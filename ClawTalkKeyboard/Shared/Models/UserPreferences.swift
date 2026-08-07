import Foundation

// MARK: - 用户偏好设置
struct UserPreferences: Codable {
    var gender: Gender?
    var birthday: Date?
    var selectedTagIds: Set<String>
    var keyboardRoleIds: Set<String>
    var currentRoleId: String?
    var keyboardType: KeyboardType
    var hapticEnabled: Bool
    var soundEnabled: Bool
    var hasCompletedGuide: Bool

    enum Gender: String, Codable {
        case male = "男"
        case female = "女"
    }

    init() {
        self.gender = nil
        self.birthday = nil
        self.selectedTagIds = []
        self.keyboardRoleIds = []
        self.currentRoleId = nil
        self.keyboardType = .qwerty
        self.hapticEnabled = true
        self.soundEnabled = false
        self.hasCompletedGuide = false
    }
}

// MARK: - 键盘类型
enum KeyboardType: Int, Codable {
    case qwerty = 0
    case t9 = 1
    case handwriting = 2
    case symbol = 3
    case number = 4

    var displayName: String {
        switch self {
        case .qwerty: return "26键"
        case .t9: return "九宫格"
        case .handwriting: return "手写"
        case .symbol: return "符号"
        case .number: return "数字"
        }
    }
}

// MARK: - 输入模式
enum InputMode: String, Codable {
    case chinese = "中文"
    case english = "英文"
}

// MARK: - 预设标签
struct PresetTag: Identifiable, Codable {
    let id: String
    let emoji: String
    let label: String
    var isSelected: Bool

    init(id: String, emoji: String, label: String, isSelected: Bool = false) {
        self.id = id
        self.emoji = emoji
        self.label = label
        self.isSelected = isSelected
    }
}

// MARK: - 预设标签数据
struct PresetTags {
    static let all: [PresetTag] = [
        PresetTag(id: "high_eq", emoji: "🧠", label: "高情商"),
        PresetTag(id: "gentle", emoji: "😊", label: "温柔"),
        PresetTag(id: "sweet", emoji: "💕", label: "撒娇"),
        PresetTag(id: "humorous", emoji: "😄", label: "幽默"),
        PresetTag(id: "caring", emoji: "🤗", label: "关心"),
        PresetTag(id: "romantic", emoji: "🌹", label: "浪漫"),
        PresetTag(id: "flirty", emoji: "😘", label: "调情"),
        PresetTag(id: "sincere", emoji: "💯", label: "真诚"),
        PresetTag(id: "warm_man", emoji: "☀️", label: "暖男"),
        PresetTag(id: "domineering", emoji: "💪", label: "霸道"),
        PresetTag(id: "funny", emoji: "🤣", label: "逗比"),
        PresetTag(id: "push_pull", emoji: "🎭", label: "推拉")
    ]

    // 标签ID到人设风格的映射
    static func tagIdToRoleTypeName(_ tagId: String) -> String {
        switch tagId {
        case "high_eq": return "HIGH_EQ"
        case "gentle": return "GENTLE"
        case "sweet": return "SWEET"
        case "humorous": return "HUMOROUS"
        case "caring": return "CARING"
        case "romantic": return "ROMANTIC"
        case "flirty": return "FLIRTY"
        case "sincere": return "SINCERE"
        case "warm_man": return "WARM_MAN"
        case "domineering": return "DOMINEERING"
        case "funny": return "FUNNY"
        case "push_pull": return "PUSH_PULL"
        default: return "GENTLE"
        }
    }
}

// MARK: - 快捷话语
struct QuickPhrases {
    static let all: [String] = [
        "在干嘛",
        "吃饭了吗",
        "想你了",
        "晚安",
        "早安",
        "我生气了",
        "你在哪"
    ]
}
