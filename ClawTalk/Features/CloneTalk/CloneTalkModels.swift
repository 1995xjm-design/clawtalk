import Foundation

/// AI 分身：口吻风格选项。
enum CloneStyle: String, Codable, CaseIterable, Identifiable {
    case casual = "随意"
    case friendly = "活泼"
    case formal = "正式"
    case concise = "简洁"

    var id: String { rawValue }

    /// 拼进提示词的风格指令。
    var instruction: String {
        switch self {
        case .casual: return "用随意、口语化的日常口吻"
        case .friendly: return "用活泼、亲切、带点幽默的口吻"
        case .formal: return "用正式、得体的书面口吻"
        case .concise: return "用简洁、直接、少废话的口吻"
        }
    }
}

/// 一条已保存的 AI 分身草稿（本地暂存，最新在前）。
struct CloneDraft: Identifiable, Codable, Equatable {
    let id: UUID
    let input: String
    let style: CloneStyle
    let text: String
    let createdAt: Date
}
