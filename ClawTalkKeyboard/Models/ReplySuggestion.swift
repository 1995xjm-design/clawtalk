import Foundation

/// 回复候选（单条），由 /api/reply-suggest 或本地兜底模板生成。
/// - text: 候选回复文本
/// - styleName: 可选风格标签（如"温柔""幽默"），未指定为 nil
struct ReplySuggestion: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let styleName: String?

    init(id: UUID = UUID(), text: String, styleName: String? = nil) {
        self.id = id
        self.text = text
        self.styleName = styleName
    }
}