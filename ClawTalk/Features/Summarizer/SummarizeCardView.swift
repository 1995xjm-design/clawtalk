import SwiftUI

/// 副主页「长文摘要」卡：显示最近摘要数，点击进入摘要页。
/// 主智能体接线：放进副主页卡片网格即可（自带 NavigationLink → SummarizeView）：
///     SummarizeCardView(settingsStore: settings)
struct SummarizeCardView: View {
    @State private var store: SummarizerStore
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore = SettingsStore(), store: SummarizerStore? = nil) {
        self.settingsStore = settingsStore
        _store = State(initialValue: store ?? SummarizerStore())
    }

    var body: some View {
        NavigationLink {
            SummarizeView(settingsStore: settingsStore, store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    if store.totalCount > 0 {
                        Text("最近 \(store.totalCount)")
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
                    Text("长文摘要")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    summaryText
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

    /// 摘要：有记录显示数量与最近日期；无记录显示诚实空状态。
    @ViewBuilder
    private var summaryText: some View {
        if let lastDate = store.lastRecordDate {
            Text("已有 \(store.totalCount) 条摘要 · 最近 \(Self.shortDate(lastDate))")
        } else {
            Text("还没有摘要，粘贴一段长文试试")
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}