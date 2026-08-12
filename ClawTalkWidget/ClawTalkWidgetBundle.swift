import SwiftUI
import WidgetKit

/// Widget 扩展统一入口：Live Activity（灵动岛/锁屏）+ 主屏小组件 + 四类功能卡。
/// 一个扩展内 @main 只能有一个，故此处用 WidgetBundle 聚合。
@main
struct ClawTalkWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClawTalkLiveActivityWidget()
        ClawTalkHomeScreenWidget()
        ClawTalkReminderWidget()
        ClawTalkStepsWidget()
        ClawTalkExpenseWidget()
        ClawTalkTravelWidget()
    }
}