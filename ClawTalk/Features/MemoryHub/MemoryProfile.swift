import Foundation

/// 第二大脑·档案条目：从本地对话按简单规则聚合出的个人档案（偏好/项目/事实/灵感）。
struct MemoryProfile: Identifiable, Codable, Equatable {
    enum Category: String, Codable, CaseIterable, Identifiable {
        case preference = "偏好"
        case project = "项目"
        case fact = "事实"
        case inspiration = "灵感"

        var id: String { rawValue }

        /// 档案 Tab 展示顺序（偏好 -> 项目 -> 事实 -> 灵感）
        static let displayOrder: [Category] = [.preference, .project, .fact, .inspiration]

        var systemImage: String {
            switch self {
            case .preference: return "heart.fill"
            case .project: return "hammer.fill"
            case .fact: return "doc.text.fill"
            case .inspiration: return "lightbulb.fill"
            }
        }
    }

    let id: UUID
    var title: String
    var category: Category
    var summary: String
    /// 来源描述，如「手机 · 主频道」
    var source: String
    var lastUpdated: Date
}
