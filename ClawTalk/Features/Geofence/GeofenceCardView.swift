import SwiftUI

/// 主页「位置提醒」卡：已启用围栏数角标 + 摘要，点击进入围栏列表。
///
/// 主智能体接线（二选一）：
/// 1. 直接把 GeofenceCardView 放进副主页卡片网格（自带 NavigationLink + 列表页）：
///    GeofenceCardView()
/// 2. 或把 HomeCard 的 destination 指向 GeofenceListView(store: GeofenceStore.shared)。
struct GeofenceCardView: View {
    @State private var store: GeofenceStore

    init(store: GeofenceStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationLink {
            GeofenceListView(store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.teal)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    // 已启用数角标：0 个不显示（摘要里有诚实文案）
                    if store.enabledRegionCount > 0 {
                        Text("已启用 \(store.enabledRegionCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.teal, in: Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("位置提醒")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    GeofenceCardSummary(store: store)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
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
        .onAppear {
            store.refreshAuthorizationState()
            store.startMonitoringIfNeeded()
        }
    }
}

/// 位置提醒卡摘要：已启用数量 + 名称（诚实空态，不造假）。
struct GeofenceCardSummary: View {
    let store: GeofenceStore

    var body: some View {
        Text(summaryText)
    }

    private var summaryText: String {
        let enabled = store.regions.filter { $0.enabled }
        guard !enabled.isEmpty else {
            return store.regions.isEmpty ? "暂无位置提醒，点这里添加" : "暂无已启用的位置提醒"
        }
        let names = enabled.prefix(2).map { $0.name }.joined(separator: "、")
        if enabled.count > 2 {
            return "已启用 \(enabled.count) 个：\(names) 等"
        }
        return "已启用：\(names)"
    }
}
