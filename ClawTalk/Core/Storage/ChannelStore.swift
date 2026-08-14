import Foundation

@Observable
final class ChannelStore {
    /// 全局共享实例：主界面与会话页共用，添加频道即时同步
    static let shared = ChannelStore()
    private let defaults = UserDefaults.standard
    private let key = "channels"

    var channels: [Channel] = []

    init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Channel].self, from: data) {
            self.channels = decoded
        }
        if channels.isEmpty {
            channels = [.default]
            save()
        }
    }

    func add(_ channel: Channel) {
        channels.append(channel)
        save()
    }

    func update(_ channel: Channel) {
        if let idx = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[idx] = channel
            save()
        }
    }

    func replace(_ channels: [Channel]) {
        self.channels = channels
        save()
    }
    func move(from source: IndexSet, to destination: Int) {
        channels.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func delete(_ channel: Channel) {
        channels.removeAll { $0.id == channel.id }
        ConversationStore.shared.clear(channelId: channel.id)
        if channels.isEmpty {
            channels = [.default]
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(channels) {
            defaults.set(data, forKey: key)
        }
        // 频道数据变化：通知主 App 刷新小组件（WidgetDataSync 单入口模式）
        NotificationCenter.default.post(name: WidgetDataSync.dataDidChangeNotification, object: nil)
    }
}
