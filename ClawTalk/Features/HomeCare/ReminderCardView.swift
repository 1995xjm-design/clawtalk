import SwiftUI

/// 副主页「提醒」卡片：今日提醒数角标 + 最近一条提醒 + 图标，点击进入提醒列表。
/// 长按卡片可快捷「新建提醒 / 查看全部」（contextMenu）。
///
/// 主智能体接线（二选一）：
/// 1. 直接把 ReminderCardView 放进副主页卡片网格（自带 NavigationLink + 提醒列表页）：
///    ReminderCardView()
/// 2. 保持现有 HomeCard 结构，仅替换 ReminderCardsPlaceholder.cards 里 id == "reminders"
///    的 destination 为 ReminderListView(store: store)，摘要行改用 ReminderCardSummary(store: store)。
struct ReminderCardView: View {
    @State private var store: CareReminderStore

    init(store: CareReminderStore? = nil) {
        _store = State(initialValue: store ?? CareReminderStore())
    }

    var body: some View {
        NavigationLink {
            ReminderListView(store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    // 今日提醒数角标：0 条不显示（摘要里有诚实文案）
                    if store.todayReminderCount > 0 {
                        Text("今日 \(store.todayReminderCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange, in: Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("提醒")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    ReminderCardSummary(store: store)
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
                ReminderListView(store: store, autoOpenAdd: true)
            } label: {
                Label("新建提醒", systemImage: "plus.circle.fill")
            }
            NavigationLink {
                ReminderListView(store: store)
            } label: {
                Label("查看全部", systemImage: "list.bullet")
            }
        }
    }
}

/// 提醒卡摘要文案：今日数量 + 最近一条（诚实空态，不造假）。
struct ReminderCardSummary: View {
    let store: CareReminderStore

    var body: some View {
        Text(summaryText)
    }

    private var summaryText: String {
        guard let next = store.nextReminder,
              let fireDate = store.nextFireDate(for: next)
        else {
            return store.reminders.isEmpty ? "暂无提醒，点这里添加" : "暂无进行中的提醒"
        }
        return "今日 \(store.todayReminderCount) 条 · \(dayLabel(fireDate)) \(timeText(fireDate)) \(next.title)"
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return weekdays[calendar.component(.weekday, from: date) - 1]
    }
}
