import AppIntents
import SwiftUI
import WidgetKit

/// 可切换卡片小组件：长按小组件 → 编辑小组件 → 选择卡片（记账/拍照记账/提醒/健康/步数/出行/会话状态）。
/// 数据与其余小组件同源（App Group：group.7518554，主 App 侧写入），无数据时显示诚实空态。

/// 可选卡片。
enum ClawTalkCardOption: String, AppEnum {
    case expense = "expense"
    case camera = "camera"
    case reminder = "reminder"
    case health = "health"
    case steps = "steps"
    case travel = "travel"
    case home = "home"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "卡片"

    static let caseDisplayRepresentations: [ClawTalkCardOption: DisplayRepresentation] = [
        .expense: "记账",
        .camera: "拍照记账",
        .reminder: "提醒",
        .health: "健康",
        .steps: "步数",
        .travel: "出行",
        .home: "会话状态"
    ]
}

/// 小组件配置意图：用户在「编辑小组件」里选择展示哪张卡片。
struct ClawTalkCardSelectionIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择卡片"
    static let description = IntentDescription("选择小组件展示的内容卡片")

    @Parameter(title: "卡片", default: .expense)
    var card: ClawTalkCardOption

    static var parameterSummary: some ParameterSummary {
        Summary("显示 \(\.$card)")
    }
}

/// 可切换卡小组件的 Timeline 条目：系统配置 + 共享数据。
struct ClawTalkSwitchableEntry: TimelineEntry {
    let date: Date
    let configuration: ClawTalkCardSelectionIntent
    let data: ClawTalkWidgetEntry
}

/// 与 ClawTalkTimelineProvider 同频刷新（15 分钟）；数据变化由主 App 主动 reload。
struct ClawTalkSwitchableTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ClawTalkSwitchableEntry {
        ClawTalkSwitchableEntry(
            date: Date(),
            configuration: ClawTalkCardSelectionIntent(),
            data: WidgetAppGroup.loadEntry()
        )
    }

    func snapshot(for configuration: ClawTalkCardSelectionIntent, in context: Context) async -> ClawTalkSwitchableEntry {
        ClawTalkSwitchableEntry(
            date: Date(),
            configuration: configuration,
            data: WidgetAppGroup.loadEntry()
        )
    }

    func timeline(for configuration: ClawTalkCardSelectionIntent, in context: Context) async -> Timeline<ClawTalkSwitchableEntry> {
        let entry = ClawTalkSwitchableEntry(
            date: Date(),
            configuration: configuration,
            data: WidgetAppGroup.loadEntry()
        )
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }
}

/// 可切换卡片小组件（kind：ClawTalkSwitchable）。
struct ClawTalkSwitchableWidget: Widget {
    let kind = "ClawTalkSwitchable"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ClawTalkCardSelectionIntent.self,
            provider: ClawTalkSwitchableTimelineProvider()
        ) { entry in
            ClawTalkSwitchableCardView(entry: entry)
        }
        .configurationDisplayName("ClawTalk 卡片")
        .description("长按编辑可切换记账/提醒/健康等卡片")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// 按配置渲染对应卡片，并挂对应深链（记账/拍照记账直达记账页）。
private struct ClawTalkSwitchableCardView: View {
    let entry: ClawTalkSwitchableEntry

    var body: some View {
        switch entry.configuration.card {
        case .expense:
            FunctionCardView(
                title: "记账",
                icon: "yensign.circle",
                content: expenseContent,
                emptyText: "本月还没有记账，点击记一笔"
            )
            .widgetURL(WidgetAppGroup.expenseURL)
        case .camera:
            ClawTalkCameraCardView(entry: entry.data)
                .widgetURL(WidgetAppGroup.cameraURL)
        case .reminder:
            FunctionCardView(
                title: "提醒",
                icon: "bell.badge",
                content: entry.data.nextReminder,
                emptyText: "暂无提醒，打开 ClawTalk 设置"
            )
            .widgetURL(WidgetAppGroup.homeURL)
        case .health:
            FunctionCardView(
                title: "健康",
                icon: "heart.fill",
                content: entry.data.health,
                emptyText: "暂无健康数据，打开 ClawTalk 同步"
            )
            .widgetURL(WidgetAppGroup.homeURL)
        case .steps:
            FunctionCardView(
                title: "步数",
                icon: "figure.walk",
                content: entry.data.steps,
                emptyText: "暂无步数数据，打开 ClawTalk 同步"
            )
            .widgetURL(WidgetAppGroup.homeURL)
        case .travel:
            FunctionCardView(
                title: "出行",
                icon: "car.fill",
                content: entry.data.travel,
                emptyText: "暂无出行记录，打开 ClawTalk 同步"
            )
            .widgetURL(WidgetAppGroup.homeURL)
        case .home:
            ClawTalkHomeScreenView(entry: entry.data)
        }
    }

    /// 记账卡文案：本月 + 今日两行。
    private var expenseContent: String {
        let month = entry.data.monthExpense.isEmpty ? "" : "本月：\(entry.data.monthExpense)"
        let today = entry.data.todayExpense.isEmpty ? "" : "今日：\(entry.data.todayExpense)"
        return [month, today].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}