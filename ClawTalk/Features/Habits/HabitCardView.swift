import SwiftUI

/// 副主页「习惯打卡」卡：今日完成 X/Y + 最长连续天数，点击进入习惯列表。
/// 与 ReminderCardView 同款圆角卡片结构，自带 NavigationLink。
/// 数据源：HabitStore（UserDefaults，与列表页同一存储；返回主页时 reload 刷新）。
struct HabitCardView: View {
    @State private var store: HabitStore

    init(store: HabitStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationLink {
            HabitsView(store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.teal)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    // 今日完成角标：今日无安排不显示（摘要里有诚实文案）
                    if store.todayDueCount > 0 {
                        Text("今日 \(store.todayCompletedCount)/\(store.todayDueCount)")
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
                    Text("习惯打卡")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    HabitCardSummary(store: store)
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
            store.reload()
        }
    }
}

/// 习惯卡摘要文案：今日完成 X/Y + 最长连续天数（诚实空态，不造假）。
struct HabitCardSummary: View {
    let store: HabitStore

    var body: some View {
        Text(summaryText)
    }

    private var summaryText: String {
        guard !store.habits.isEmpty else { return "暂无习惯，点这里添加" }

        let todayText: String
        if store.todayDueCount == 0 {
            todayText = "今日无打卡安排"
        } else {
            todayText = "今日完成 \(store.todayCompletedCount)/\(store.todayDueCount)"
        }

        let longest = store.longestStreak
        if longest > 0 {
            return "\(todayText) · 最长连续 \(longest) 天"
        }
        return "\(todayText) · 坚持打卡，记录连续天数"
    }
}
