import SwiftUI
import WidgetKit

/// ClawTalk 品牌红（与主 App Theme.openClawRed 一致）。
private let clawTalkRed = Color(red: 0.85, green: 0.18, blue: 0.15)

/// 功能卡通用外壳：图标 + 标题 + 内容 + 诚实空态。
/// 数据全部来自 App Group（group.7518554），主 App 侧写入；无数据时展示「打开 ClawTalk 同步」引导，
/// 不伪造数值。
private struct FunctionCardView: View {
    let title: String
    let icon: String
    let content: String
    let emptyText: String

    @Environment(\.widgetFamily) private var family

    private var hasContent: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(clawTalkRed)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 2)

            Text(hasContent ? content : emptyText)
                .font(family == .systemMedium ? .title3 : .subheadline)
                .fontWeight(.medium)
                .foregroundStyle(hasContent ? Color.primary : Color.secondary)
                .lineLimit(family == .systemMedium ? 4 : 3)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 2)

            Text("ClawTalk")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
    }
}

// MARK: - 提醒卡

/// 提醒事项卡：显示下一条提醒（widget_next_reminder）。
struct ClawTalkReminderWidget: Widget {
    let kind = "ClawTalkReminder"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClawTalkTimelineProvider()) { entry in
            FunctionCardView(
                title: "提醒",
                icon: "bell.badge",
                content: entry.nextReminder,
                emptyText: "暂无提醒，打开 ClawTalk 设置"
            )
            .widgetURL(WidgetAppGroup.homeURL)
        }
        .configurationDisplayName("ClawTalk 提醒")
        .description("查看下一条提醒事项")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 步数卡

/// 步数卡：显示今日步数（widget_steps）。
struct ClawTalkStepsWidget: Widget {
    let kind = "ClawTalkSteps"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClawTalkTimelineProvider()) { entry in
            FunctionCardView(
                title: "步数",
                icon: "figure.walk",
                content: entry.steps,
                emptyText: "暂无步数数据，打开 ClawTalk 同步"
            )
            .widgetURL(WidgetAppGroup.homeURL)
        }
        .configurationDisplayName("ClawTalk 步数")
        .description("查看今日步数")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 记账卡

/// 记账卡：显示本月收支（widget_expense）。
struct ClawTalkExpenseWidget: Widget {
    let kind = "ClawTalkExpense"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClawTalkTimelineProvider()) { entry in
            FunctionCardView(
                title: "记账",
                icon: "yensign.circle",
                content: entry.expense,
                emptyText: "暂无记账数据，打开 ClawTalk 记一笔"
            )
            .widgetURL(WidgetAppGroup.homeURL)
        }
        .configurationDisplayName("ClawTalk 记账")
        .description("查看本月收支概览")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 出行卡

/// 出行卡：显示停车/出行记录（widget_travel）。
struct ClawTalkTravelWidget: Widget {
    let kind = "ClawTalkTravel"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClawTalkTimelineProvider()) { entry in
            FunctionCardView(
                title: "出行",
                icon: "car.fill",
                content: entry.travel,
                emptyText: "暂无出行记录，打开 ClawTalk 同步"
            )
            .widgetURL(WidgetAppGroup.homeURL)
        }
        .configurationDisplayName("ClawTalk 出行")
        .description("查看停车与出行记录")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}