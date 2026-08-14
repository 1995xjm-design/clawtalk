import SwiftUI
import WidgetKit

/// ClawTalk 品牌红（与主 App Theme.openClawRed 一致）。
private let clawTalkRed = Color(red: 0.85, green: 0.18, blue: 0.15)

/// 功能卡通用外壳：图标 + 标题 + 内容 + 诚实空态。
/// 数据全部来自 App Group（group.7518554），主 App 侧写入；无数据时展示「打开 ClawTalk 同步」引导，
/// 不伪造数值。（可切换卡片小组件也复用本视图。）
struct FunctionCardView: View {
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

/// 记账卡：显示今日/本月收支（widget_expense_today / widget_expense_month），点击打开记账页。
struct ClawTalkExpenseWidget: Widget {
    let kind = "ClawTalkExpense"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClawTalkTimelineProvider()) { entry in
            FunctionCardView(
                title: "记账",
                icon: "yensign.circle",
                content: expenseContent(entry),
                emptyText: "本月还没有记账，点击记一笔"
            )
            .widgetURL(WidgetAppGroup.expenseURL)
        }
        .configurationDisplayName("ClawTalk 记账")
        .description("查看今日/本月收支，点击快速记账")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// 记账卡文案：本月 + 今日两行（主 App 已格式化好收支摘要）。
private func expenseContent(_ entry: ClawTalkWidgetEntry) -> String {
    let month = entry.monthExpense.isEmpty ? "" : "本月：\(entry.monthExpense)"
    let today = entry.todayExpense.isEmpty ? "" : "今日：\(entry.todayExpense)"
    return [month, today].filter { !$0.isEmpty }.joined(separator: "\n")
}

// MARK: - 拍照记账卡

/// 拍照按钮卡：快捷唤起拍照记账（clawtalk://camera → 主 App 打开记账页）。
struct ClawTalkCameraWidget: Widget {
    let kind = "ClawTalkCamera"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClawTalkTimelineProvider()) { entry in
            ClawTalkCameraCardView(entry: entry)
                .widgetURL(WidgetAppGroup.cameraURL)
        }
        .configurationDisplayName("ClawTalk 拍照记账")
        .description("快捷打开拍照记账")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// 拍照记账卡片视图（独立拍照卡与可切换卡片小组件共用）。
struct ClawTalkCameraCardView: View {
    let entry: ClawTalkWidgetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.headline)
                    .foregroundStyle(clawTalkRed)
                Text("拍照记账")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 2)

            HStack(spacing: 10) {
                Image(systemName: "viewfinder.circle.fill")
                    .font(family == .systemMedium ? .largeTitle : .title2)
                    .foregroundStyle(clawTalkRed)
                VStack(alignment: .leading, spacing: 3) {
                    Text("点击打开记账")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(todayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
            }

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

    private var todayText: String {
        entry.todayExpense.isEmpty ? "今日还没有记账" : "今日：\(entry.todayExpense)"
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