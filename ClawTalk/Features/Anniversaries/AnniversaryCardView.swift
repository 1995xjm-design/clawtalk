import SwiftUI

/// 主页「纪念日」卡片：最近纪念日 + 剩余天数角标 + 摘要，点击进入纪念日列表。
/// 与 ReminderCardView 同款：自带 NavigationLink + AnniversaryStore。
///
/// 主智能体接线：在 HomeTabView 快捷入口 LazyVGrid 里加一行 AnniversaryCardView()
/// （参考 ReminderCardView() 的写法）。
struct AnniversaryCardView: View {
    @State private var store: AnniversaryStore

    init(store: AnniversaryStore? = nil) {
        _store = State(initialValue: store ?? AnniversaryStore())
    }

    var body: some View {
        NavigationLink {
            AnniversariesView(store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.pink)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    // 最近纪念日剩余天数角标：无数据不显示（摘要里有诚实文案）
                    if let days = nearestDays {
                        Text(days == 0 ? "今天" : days == 1 ? "明天" : "还有 \(days) 天")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(days == 0 ? Color.openClawRed : Color.pink, in: Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("纪念日")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    summary
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
        .contextMenu {
            NavigationLink {
                AnniversariesView(store: store, autoOpenAdd: true)
            } label: {
                Label("新建纪念日", systemImage: "plus.circle.fill")
            }
            NavigationLink {
                AnniversariesView(store: store)
            } label: {
                Label("查看全部", systemImage: "list.bullet")
            }
        }
    }

    /// 最近一个纪念日的剩余天数（无数据/一次性已过返回 nil，诚实空态）。
    private var nearestDays: Int? {
        guard let anniversary = store.nextAnniversary else { return nil }
        return store.daysUntilNext(for: anniversary)
    }

    /// 卡摘要：最近纪念日 + 剩余天数；无数据诚实空态，不塞假数据。
    private var summary: Text {
        if let anniversary = store.nextAnniversary,
           let days = store.daysUntilNext(for: anniversary) {
            if days == 0 {
                return Text("今天 · \(anniversary.name)")
            }
            return Text("还有 \(days) 天 · \(anniversary.name)")
        }
        return Text(store.anniversaries.isEmpty ? "暂无纪念日，点这里添加" : "暂无即将到来的纪念日")
    }
}
