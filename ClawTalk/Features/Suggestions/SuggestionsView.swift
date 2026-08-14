import Foundation
import SwiftUI

/// 「主动建议」列表页：未读建议按优先级 / 时间排序，滑动已读 / 忽略，含通知开关。
struct SuggestionsView: View {
    @State private var store: SuggestionStore

    init(store: SuggestionStore? = nil) {
        _store = State(initialValue: store ?? SuggestionStore())
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { store.notificationsEnabled },
                    set: { store.notificationsEnabled = $0 }
                )) {
                    Label("高优先级建议通知", systemImage: "bell.badge.fill")
                }
            } footer: {
                Text("每天首次生成建议时，高优先级建议会通过本地通知提醒。")
            }

            Section {
                if store.suggestions.isEmpty {
                    emptyState
                } else {
                    ForEach(store.suggestions) { suggestion in
                        SuggestionRow(suggestion: suggestion)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("已读") { store.markRead(id: suggestion.id) }
                                    .tint(.blue)
                                Button("忽略") { store.ignore(id: suggestion.id) }
                                    .tint(.gray)
                            }
                    }
                }
            } header: {
                if !store.suggestions.isEmpty {
                    Text("未读建议（\(store.suggestions.count)）")
                }
            }
        }
        .navigationTitle("主动建议")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("暂无建议", systemImage: "sparkles")
                .font(.headline)
            Text("有值得注意的事情时（步数偏少、习惯没打卡、支出偏高、灵感未沉淀、明天提醒较多等），会在这里出现。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

/// 建议行：类型图标 + 优先级角标 + 标题 + 正文 + 动作提示。
private struct SuggestionRow: View {
    let suggestion: Suggestion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: suggestion.type.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(suggestion.type.themeColor)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(suggestion.title)
                        .font(.subheadline.weight(.semibold))
                    priorityBadge
                    Spacer(minLength: 4)
                    Text(relativeTimeText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(suggestion.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let actions = suggestion.action, !actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(actions, id: \.self) { action in
                            Text(action)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(suggestion.type.themeColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(suggestion.type.themeColor.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var priorityBadge: some View {
        Text(suggestion.priority.displayName)
            .font(.caption2.bold())
            .foregroundStyle(suggestion.priority.themeColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(suggestion.priority.themeColor.opacity(0.14))
            .clipShape(Capsule())
    }

    private var relativeTimeText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(suggestion.createdAt) {
            return Self.timeFormatter.string(from: suggestion.createdAt)
        }
        if calendar.isDateInYesterday(suggestion.createdAt) {
            return "昨天"
        }
        return Self.dateFormatter.string(from: suggestion.createdAt)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}

/// 主页「主动建议」卡：未读角标 + 最新一条摘要；.task 触发每日建议生成。
/// 与 HealthCardView 同款卡片风格，直接放进主页 LazyVGrid 一格。
struct SuggestionHomeCard: View {
    @State private var store = SuggestionStore()

    var body: some View {
        NavigationLink {
            SuggestionsView(store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "sparkles")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.indigo)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if store.unreadCount > 0 {
                                Text("\(store.unreadCount)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.red))
                                    .offset(x: 6, y: -6)
                            }
                        }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("主动建议")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if let latest = store.latestSuggestion {
                        Text("\(latest.priority.displayName) · \(latest.title)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(latest.priority.themeColor)
                        Text(latest.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("暂无建议，有值得注意的事会出现在这里")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .task { await store.refresh() }
    }
}

// MARK: - 展示扩展（颜色只在视图层，模型保持纯 Foundation）

extension SuggestionType {
    /// 类型主题色（深色 / 浅色下均有对比度）。
    var themeColor: Color {
        switch self {
        case .health: return .green
        case .finance: return .orange
        case .habit: return .blue
        case .memory: return .yellow
        case .efficiency: return .indigo
        }
    }
}

extension SuggestionPriority {
    /// 优先级主题色。
    var themeColor: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        }
    }
}
