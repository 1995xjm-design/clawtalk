import Foundation
import WidgetKit

/// 主屏小组件数据读取契约（App Group，主 App 侧负责写入）：
/// - widget_channel_name:   当前频道名（String）
/// - widget_gateway_status: 网关状态文案（String，如「已连接」「未连接」）
/// - widget_recent_session: 最近一条会话内容摘要（String）
/// - widget_next_reminder:  下一条提醒文案（String，如「14:30 喝水」）
/// - widget_steps:          今日步数文案（String，如「今日 5,234 步」；主 App 格式化）
/// - widget_expense:        本月记账文案（String，如「本月支出 ¥123」；主 App 格式化）
/// - widget_travel:         出行/停车文案（String，如「停车：商场 B2」；主 App 格式化）
/// - widget_updated_at:     最后更新时间戳（TimeInterval）
enum WidgetAppGroup {
    static let suiteName = "group.7518554"
    static let channelNameKey = "widget_channel_name"
    static let gatewayStatusKey = "widget_gateway_status"
    static let recentSessionKey = "widget_recent_session"
    static let nextReminderKey = "widget_next_reminder"
    static let stepsKey = "widget_steps"
    static let expenseKey = "widget_expense"
    static let travelKey = "widget_travel"
    static let updatedAtKey = "widget_updated_at"

    static func loadEntry(date: Date = Date()) -> ClawTalkWidgetEntry {
        let defaults = UserDefaults(suiteName: suiteName)
        return ClawTalkWidgetEntry(
            date: date,
            channelName: defaults?.string(forKey: channelNameKey) ?? "",
            gatewayStatus: defaults?.string(forKey: gatewayStatusKey) ?? "",
            recentSession: defaults?.string(forKey: recentSessionKey) ?? "",
            nextReminder: defaults?.string(forKey: nextReminderKey) ?? "",
            steps: defaults?.string(forKey: stepsKey) ?? "",
            expense: defaults?.string(forKey: expenseKey) ?? "",
            travel: defaults?.string(forKey: travelKey) ?? ""
        )
    }

    /// 快捷打开链接：clawtalk://open?channel=频道名；未绑定频道时退化为 clawtalk://home（只打开 App）。
    static func widgetURL(for entry: ClawTalkWidgetEntry) -> URL? {
        var components = URLComponents()
        components.scheme = "clawtalk"
        if entry.channelName.isEmpty {
            components.host = "home"
        } else {
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "channel", value: entry.channelName)]
        }
        return components.url
    }

    /// 功能卡通用打开链接：打开 App 主页（主 App 处理深链）。
    static let homeURL = URL(string: "clawtalk://home")
}

struct ClawTalkWidgetEntry: TimelineEntry {
    let date: Date
    let channelName: String
    let gatewayStatus: String
    let recentSession: String
    let nextReminder: String
    /// 今日步数文案（空 = 无数据）
    let steps: String
    /// 本月记账文案（空 = 无数据）
    let expense: String
    /// 出行/停车文案（空 = 无数据）
    let travel: String
}

/// 每 15 分钟刷新一次；无数据时展示诚实空状态（未同步/暂无会话）。
struct ClawTalkTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClawTalkWidgetEntry {
        ClawTalkWidgetEntry(
            date: Date(),
            channelName: "ClawTalk",
            gatewayStatus: "",
            recentSession: "",
            nextReminder: "",
            steps: "",
            expense: "",
            travel: ""
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ClawTalkWidgetEntry) -> Void) {
        completion(WidgetAppGroup.loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClawTalkWidgetEntry>) -> Void) {
        let entry = WidgetAppGroup.loadEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}