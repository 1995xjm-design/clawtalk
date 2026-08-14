import SwiftUI

/// 副主页「会议纪要」卡：显示最近纪要数，点击进入纪要列表。
/// 主智能体接线：放进副主页卡片网格即可（自带 NavigationLink → MeetingListView）：
///     MeetingCardView(settingsStore: settings)
struct MeetingCardView: View {
    @State private var store: MeetingStore
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore = SettingsStore(), store: MeetingStore? = nil) {
        self.settingsStore = settingsStore
        _store = State(initialValue: store ?? MeetingStore())
    }

    var body: some View {
        NavigationLink {
            MeetingListView(settingsStore: settingsStore, store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "person.3.fill")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.indigo)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    if store.totalCount > 0 {
                        Text("最近 \(store.totalCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.indigo, in: Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("会议纪要")
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

    /// 摘要：有纪要显示数量与最近日期；无纪要显示诚实空状态。
    @ViewBuilder
    private var summaryText: some View {
        if let lastDate = store.lastNoteDate {
            Text("已有 \(store.totalCount) 条纪要 · 最近 \(Self.shortDate(lastDate))")
        } else {
            Text("还没有纪要，录一段会议试试")
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
