import SwiftUI

/// 副主页「每日简报」卡片：仿 HomeCardView 样式（图标 + 标题 + 摘要），点击进入每日简报页。
/// 今日提醒数随 CareReminderStore 实时更新；日程/待办/天气在简报页内诚实展示。
///
/// 主智能体接线：在 HomeTabView 快捷入口卡片网格（LazyVGrid）里加一行：
///     DailyBriefCardView()
/// （HomeTabView 位于 Features/Home/，不在本层改动范围内；已确认 DailyBriefEntryButton
///   也可直接放进任意视图，它自带 fullScreenCover）
struct DailyBriefCardView: View {
    @State private var store: CareReminderStore

    init(store: CareReminderStore? = nil) {
        _store = State(initialValue: store ?? CareReminderStore())
    }

    var body: some View {
        NavigationLink {
            DailyBriefView(store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "sun.max.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.indigo)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("每日简报")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(summaryText)
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
    }

    /// 摘要：今日提醒数实时显示；无提醒时诚实空态（日程/待办需进简报页看授权状态）。
    private var summaryText: String {
        let today = store.todayReminderCount
        if today > 0 {
            return "今天 \(today) 条提醒 · 日程与待办一览"
        }
        if store.reminders.isEmpty {
            return "今天的日程、待办与提醒（天气待接入）"
        }
        return "今天暂无将触发的提醒 · 日程与待办一览"
    }
}
