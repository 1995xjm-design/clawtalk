import SwiftUI

/// 日记类别徽章：类别名 + 图标 + 主题色胶囊背景。
struct DiaryCategoryBadge: View {
    let category: DiaryCategory

    var body: some View {
        Label(category.rawValue, systemImage: category.iconName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(category.themeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(category.themeColor.opacity(0.14), in: Capsule())
    }
}

extension DiaryCategory {
    /// 类别图标（SF Symbols）
    var iconName: String {
        switch self {
        case .diary: return "book.closed.fill"
        case .todo: return "checkmark.circle.fill"
        case .inspiration: return "lightbulb.fill"
        }
    }

    /// 类别主题色（深色/浅色下均有对比度）
    var themeColor: Color {
        switch self {
        case .diary: return .blue
        case .todo: return .orange
        case .inspiration: return .purple
        }
    }
}
