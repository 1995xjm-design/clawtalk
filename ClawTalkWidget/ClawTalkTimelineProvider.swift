import Foundation
import WidgetKit

/// 主屏小组件数据读取契约（App Group，主 App 侧负责写入）：
/// - widget_channel_name:   当前频道名（String）
/// - widget_gateway_status: 网关状态文案（String，如「已连接」「未连接」）
/// - widget_recent_session: 最近一条会话内容摘要（String）
/// - widget_next_reminder:  下一条提醒文案（String，如「14:30 喝水」）
/// - widget_updated_at:     最后更新时间戳（TimeInterval）
enum WidgetAppGroup {
    static let suiteName = "group.7518554"
    static let channelNameKey = "widget_channel_name"
    static let gatewayStatusKey = "widget_gateway_status"
    static let recentSessionKey = "widget_recent_session"
    static let nextReminderKey = "widget_next_reminder"
    static let updatedAtKey = "widget_updated_at"

    static func loadEntry(date: Date = Date()) -> ClawTalkWidgetEntry {
        let defaults = UserDefaults(suiteName: suiteName)
        return ClawTalkWidgetEntry(
            date: date,
            channelName: defaults?.string(forKey: channelNameKey) ?? "",
            gatewayStatus: defaults?.string(forKey: gatewayStatusKey) ?? "",
            recentSession: defaults?.string(forKey: recentSessionKey) ?? "",
            nextReminder: defaults?.string(forKey: nextReminderKey) ?? ""
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
}

struct ClawTalkWidgetEntry: TimelineEntry {
    let date: Date
    let channelName: String
    let gatewayStatus: String
    let recentSession: String
    let nextReminder: String
}

/// 每 15 分钟刷新一次；无数据时展示诚实空状态（未同步/暂无会话）。
struct ClawTalkTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClawTalkWidgetEntry {
        ClawTalkWidgetEntry(
            date: Date(),
            channelName: "ClawTalk",
            gatewayStatus: "",
            recentSession: "",
            nextReminder: ""
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
