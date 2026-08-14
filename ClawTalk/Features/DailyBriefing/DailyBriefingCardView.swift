import SwiftUI
import EventKit

/// 主页「每日播报」卡：今日提醒数 + 今日日程数摘要，点击进入每日播报页（一键语音朗读）。
/// 样式对齐 DailyBriefCardView（图标 + 标题 + 摘要）；日程数仅在日历已授权时读取，
/// 未授权/失败时诚实显示「日程待授权」，不主动弹权限框。
///
/// 主智能体接线：在 HomeTabView 快捷入口卡片网格（LazyVGrid）里加一行：
///     DailyBriefingCardView(settings: settings)
struct DailyBriefingCardView: View {
    private let settings: SettingsStore
    @State private var store: CareReminderStore
    @State private var scheduleCount: Int?

    init(settings: SettingsStore? = nil, store: CareReminderStore? = nil) {
        self.settings = settings ?? SettingsStore()
        _store = State(initialValue: store ?? CareReminderStore())
    }

    var body: some View {
        NavigationLink {
            DailyBriefingView(settings: settings, careStore: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(.title3, weight: .semibold))
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
                    Text("每日播报")
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
        .task { await loadScheduleCountIfAuthorized() }
    }

    /// 摘要：提醒数实时显示；日程数仅在授权后显示，未授权诚实显示「日程待授权」。
    private var summaryText: String {
        var parts: [String] = []
        let today = store.todayReminderCount
        if today > 0 {
            parts.append("今天 \(today) 条提醒")
        } else if store.reminders.isEmpty {
            parts.append("暂无提醒")
        } else {
            parts.append("今日无将触发提醒")
        }
        if let scheduleCount {
            parts.append(scheduleCount > 0 ? "\(scheduleCount) 个日程" : "今天没日程")
        } else {
            parts.append("日程待授权")
        }
        parts.append("一键语音播报")
        return parts.joined(separator: " · ")
    }

    /// 只在日历已授权时读取今日日程数（不主动弹授权框），失败静默置 nil。
    private func loadScheduleCountIfAuthorized() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else {
            scheduleCount = nil
            return
        }
        do {
            let events = try await CalendarCapability.listEvents(daysAhead: 1, daysBack: 1)
            let formatter = ISO8601DateFormatter()
            scheduleCount = events.filter { event in
                guard let start = formatter.date(from: event.startDate) else { return false }
                return Calendar.current.isDateInToday(start)
            }.count
        } catch {
            scheduleCount = nil
        }
    }
}
