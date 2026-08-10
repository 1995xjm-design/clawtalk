import Foundation

/// 键盘扩展本地错误日志收集器（环形，最多保留 100 条）。
///
/// 键盘 target 无法直接复用主 App 的 LogCollector 类，这里按相同 key 与 Entry
/// 格式实现一份键盘侧写入逻辑：
/// - 优先写 App Group（group.com.openclaw.clawtalk）的 "app_error_logs"，
///   与 ClawTalk 主 App「日志与诊断」页共享；
/// - App Group 套件取不到时（如免费签名无 App Groups entitlement）回退
///   UserDefaults.standard 本地保存，键盘侧仍能独立记录，不崩溃。
enum KeyboardLogCollector {
    /// 存储 key，与主 App LogCollector 保持一致
    private static let key = "app_error_logs"
    private static let limit = 100

    /// Entry 结构与主 App LogCollector.Entry 完全一致（Codable JSON）
    struct Entry: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let module: String
        let message: String
    }

    /// App Group 套件（初始化失败时回退 standard）
    private static let appGroupDefaults = UserDefaults(suiteName: AppConstants.appGroupId)
    private static var defaults: UserDefaults {
        appGroupDefaults ?? .standard
    }

    /// 记录一条错误：追加到尾部，超过 100 条时丢弃最旧
    static func record(module: String, _ message: String) {
        var entries = load()
        entries.append(Entry(id: UUID(), timestamp: Date(), module: module, message: message))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    /// 读取全部日志（与主 App 同 key 同格式，可互相读取）
    static func load() -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    /// 清空日志
    static func clear() {
        defaults.removeObject(forKey: key)
    }
}
