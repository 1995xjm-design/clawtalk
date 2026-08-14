import SwiftUI

/// 主页「周报月报」卡：本周摘要一行（日记篇数 / 记账支出 / 打卡次数），
/// 点击进入周报月报页（生成 / 朗读 / 分享）。
/// 样式对齐 DailyBriefingCardView（图标 + 标题 + 摘要）。
///
/// 主智能体接线：在 HomeTabView 快捷入口卡片网格（LazyVGrid）里加一行：
///     ReportCardView(settings: settings)
struct ReportCardView: View {
    private let settings: SettingsStore
    @State private var summaryText = "本周摘要生成中…"

    init(settings: SettingsStore? = nil) {
        self.settings = settings ?? SettingsStore()
    }

    var body: some View {
        NavigationLink {
            ReportView(settings: settings)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.teal)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("周报月报")
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
        .task { loadWeekSummary() }
    }

    /// 本周摘要：本地数据实时统计（诚实，无数据如实说；数据源失败不影响卡片）。
    private func loadWeekSummary() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -6, to: today),
              let endExclusive = calendar.date(byAdding: .day, value: 1, to: today) else {
            summaryText = "本周暂无记录"
            return
        }
        let range = start..<endExclusive

        let diary = VoiceDiaryViewModel(settingsStore: settings)
        let expense = ExpenseStore()
        let habits = HabitStore()

        let diaryCount = diary.entries.filter { range.contains($0.date) }.count
        let expenseTotal = expense.entries
            .filter { range.contains($0.date) && $0.type == .expense }
            .reduce(0) { $0 + $1.amount }
        let checkedCount = habits.habits.reduce(0) { count, habit in
            habit.checkIns.values.reduce(count) { partial, date in
                range.contains(date) ? partial + 1 : partial
            }
        }

        var parts: [String] = []
        if diaryCount > 0 { parts.append("日记 \(diaryCount) 篇") }
        if expenseTotal > 0 { parts.append("支出 \(expenseTotal.expenseAmountText) 元") }
        if checkedCount > 0 { parts.append("打卡 \(checkedCount) 次") }

        if parts.isEmpty {
            summaryText = "自动汇总一周/一月的活动"
        } else {
            summaryText = "本周" + parts.joined(separator: " · ")
        }
    }
}
