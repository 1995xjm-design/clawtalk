import Foundation

/// 本地错误日志收集器（环形，最多保留 100 条），供「日志与诊断」查看与同步到 OpenClaw。
/// 日志存放在 App Group（group.7518554），主 App 与键盘扩展共享同一份日志；
/// 升级前存在 standard 的旧日志会在首次访问时自动迁移。
enum LogCollector {
    private static let appGroupSuiteName = "group.7518554"
    private static let key = "app_error_logs"
    private static let limit = 100

    /// App Group 共享存储；套件初始化失败时回退 standard（不丢日志能力）。
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }

    /// 迁移升级前 standard 中的旧日志与待上报计数（一次性）。
    private static func migrateLegacyDataIfNeeded() {
        let shared = UserDefaults(suiteName: appGroupSuiteName)
        if let legacy = UserDefaults.standard.data(forKey: key), shared?.data(forKey: key) == nil {
            shared?.set(legacy, forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        if UserDefaults.standard.object(forKey: pendingKey) != nil, shared?.object(forKey: pendingKey) == nil {
            shared?.set(UserDefaults.standard.integer(forKey: pendingKey), forKey: pendingKey)
            UserDefaults.standard.removeObject(forKey: pendingKey)
        }
    }

    struct Entry: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let module: String
        let message: String
        /// 记录时的 App 版本（shortVersion + build），用于电脑端区分错误来源版本。
        var appVersion: String?
    }

    /// 当前 App 版本号（如 1.2.2(5)）；读不到时返回空串。
    static var currentVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        if short.isEmpty && build.isEmpty { return "" }
        return short.isEmpty ? "(\(build))" : build.isEmpty ? short : "\(short)(\(build))"
    }

    static func record(module: String, _ message: String) {
        var entries = load()
        entries.append(Entry(id: UUID(), timestamp: Date(), module: module, message: message, appVersion: currentVersion))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        migrateLegacyDataIfNeeded()
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
        // C1：累计达到阈值自动触发上传（App 层监听执行，成功后重置计数）
        let count = defaults.integer(forKey: pendingKey) + 1
        defaults.set(count, forKey: pendingKey)
        if count >= autoUploadThreshold {
            NotificationCenter.default.post(name: autoUploadNotification, object: nil)
        }
    }

    static func load() -> [Entry] {
        migrateLegacyDataIfNeeded()
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    static func clear() {
        migrateLegacyDataIfNeeded()
        defaults.removeObject(forKey: key)
    }

    // MARK: - 自动上报（C1：累计 20 条自动发电脑 inbound）

    private static let pendingKey = "app_error_logs_pending_upload"
    private static let autoUploadThreshold = 20
    static let autoUploadNotification = Notification.Name("clawtalkAutoUploadLogs")

    /// 待上报计数（自上次成功上传/清零后累计的记录条数）。
    static var pendingUploadCount: Int {
        migrateLegacyDataIfNeeded()
        return defaults.integer(forKey: pendingKey)
    }

    static func resetPendingUploadCount() {
        migrateLegacyDataIfNeeded()
        defaults.set(0, forKey: pendingKey)
    }

    /// 导出全部日志为带时间戳的文本（供自动上传/手动发送复用）。
    static func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let lines = load().map { entry -> String in
            let time = formatter.string(from: entry.timestamp)
            let version = entry.appVersion.map { "[\($0)] " } ?? ""
            return "\(time) [\(entry.module)] \(version)\(entry.message)"
        }
        return lines.joined(separator: "\n")
    }
}
