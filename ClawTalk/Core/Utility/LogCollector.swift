import Foundation

/// 本地错误日志收集器（环形，最多保留 100 条），供「日志与诊断」查看与同步到 OpenClaw。
enum LogCollector {
    private static let key = "app_error_logs"
    private static let limit = 100

    struct Entry: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let module: String
        let message: String
    }

    static func record(module: String, _ message: String) {
        var entries = load()
        entries.append(Entry(id: UUID(), timestamp: Date(), module: module, message: message))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
