import SwiftUI

/// 主页「睡前陪伴」卡：月亮图标 +「说晚安」，点击进入睡前陪伴页（TTS 温柔朗读晚安）。
/// 样式对齐 DailyBriefingCardView（图标 + 标题 + 摘要）；
/// 摘要只读本地 CareReminderStore（不弹权限框），诚实显示明日提醒数。
///
/// 主智能体接线：在 HomeTabView 快捷入口卡片网格（LazyVGrid）里加一行：
///     WindDownCardView(settings: settings)
struct WindDownCardView: View {
    private let settings: SettingsStore
    @State private var store: CareReminderStore
    @State private var tomorrowReminderCount: Int?

    init(settings: SettingsStore? = nil, store: CareReminderStore? = nil) {
        self.settings = settings ?? SettingsStore()
        _store = State(initialValue: store ?? CareReminderStore())
    }

    var body: some View {
        NavigationLink {
            WindDownView(settings: settings, careStore: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "moon.stars.fill")
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
                    Text("睡前陪伴")
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
        .task { await load() }
    }

    /// 摘要：说晚安 + 明日提醒数（本地读取，未授权/无数据诚实显示）。
    private var summaryText: String {
        var parts: [String] = ["说晚安"]
        if let tomorrowReminderCount {
            parts.append(tomorrowReminderCount > 0 ? "明天 \(tomorrowReminderCount) 条提醒" : "明天暂无提醒")
        }
        parts.append("温柔的今日总结")
        return parts.joined(separator: " · ")
    }

    /// 只读本地 CareReminderStore 的明日提醒数（不弹任何权限框），失败静默置 nil。
    private func load() async {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        tomorrowReminderCount = store.upcomingReminders
            .filter { calendar.isDate($0.fireDate, inSameDayAs: tomorrow) }
            .count
    }
}
