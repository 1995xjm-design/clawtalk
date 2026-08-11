import Combine
import Foundation

/// 从 App Group（group.7518554）读取主 App 每 3 秒同步的频道列表。
/// 数据键 channels_list 由 ClawTalkApp.syncChannelsToShare 写入（ShareChannelEntry
/// 格式），主 App 未配置/未启动时读不到数据，这里保持诚实空状态。
final class WatchChannelStore: ObservableObject {
    static let groupSuiteName = "group.7518554"
    static let channelsKey = "channels_list"

    @Published private(set) var channels: [WatchChannel] = []

    /// 从 App Group 刷新频道列表；无数据时清空，不伪造默认频道。
    func refresh() {
        guard let defaults = UserDefaults(suiteName: Self.groupSuiteName),
              let data = defaults.data(forKey: Self.channelsKey),
              let decoded = try? JSONDecoder().decode([WatchChannel].self, from: data) else {
            channels = []
            return
        }
        channels = decoded
    }
}