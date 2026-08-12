import SwiftUI

/// 副主页「语音记账」卡：本月支出摘要，点击进入记账列表页（自带 NavigationLink）。
///
/// 接线说明（主智能体统一接线，本文件不修改 HomeTabView.swift）：
/// 1. `HomeTabView.swift` 已持有 `private let settings: SettingsStore`，
///    在「快捷入口」`LazyVGrid(columns: columns, spacing: 12)` 里（语音日记卡附近）
///    增加一格即可，无需再包 NavigationLink（卡片自带）：
///    `ExpenseCardView(settings: settings)`
/// 2. 卡片与列表页各自持有 ExpenseStore 实例，共用 UserDefaults 同一数据源；
///    从列表页返回时卡片 `.task` 重新 `reload()` 刷新摘要。
/// 3. 若希望卡片与列表页实时共享内存状态，可改由 HomeTabView 创建共享
///    ExpenseStore 传入两处（本卡与 ExpenseListView 的 init 均已预留 store 参数）。
struct ExpenseCardView: View {
    @State private var store: ExpenseStore
    private let settings: SettingsStore

    init(settings: SettingsStore, store: ExpenseStore? = nil) {
        self.settings = settings
        _store = State(initialValue: store ?? ExpenseStore())
    }

    var body: some View {
        NavigationLink {
            ExpenseListView(settingsStore: settings)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "yensign.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("语音记账")
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
        .task { store.reload() }
    }

    /// 本月摘要：优先显示支出；本月无任何账目时诚实空状态。
    private var summaryText: String {
        let summary = store.monthSummary()
        if summary.expense <= 0 && summary.income <= 0 {
            return "本月还没有记账，按住说话记一笔"
        }
        if summary.income <= 0 {
            return "本月支出 ¥\(summary.expense.expenseAmountText)"
        }
        if summary.expense <= 0 {
            return "本月收入 ¥\(summary.income.expenseAmountText)"
        }
        return "本月支出 ¥\(summary.expense.expenseAmountText) · 收入 ¥\(summary.income.expenseAmountText)"
    }
}