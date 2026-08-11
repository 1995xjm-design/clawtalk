import SwiftUI
import WidgetKit

/// 主屏桌面小组件：显示最近会话与网关状态，每 15 分钟刷新。
struct ClawTalkHomeScreenWidget: Widget {
    let kind = "ClawTalkHomeScreen"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClawTalkTimelineProvider()) { entry in
            ClawTalkHomeScreenView(entry: entry)
        }
        .configurationDisplayName("ClawTalk")
        .description("查看最近会话与网关状态")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}