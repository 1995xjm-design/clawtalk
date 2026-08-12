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
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // C1：累计达到阈值自动触发上传（App 层监听执行，成功后重置计数）
        let count = UserDefaults.standard.integer(forKey: pendingKey) + 1
        UserDefaults.standard.set(count, forKey: pendingKey)
        if count >= autoUploadThreshold {
            NotificationCenter.default.post(name: autoUploadNotification, object: nil)
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

    // MARK: - 自动上报（C1：累计 20 条自动发电脑 inbound）

    private static let pendingKey = "app_error_logs_pending_upload"
    private static let autoUploadThreshold = 20
    static let autoUploadNotification = Notification.Name("clawtalkAutoUploadLogs")

    /// 待上报计数（自上次成功上传/清零后累计的记录条数）。
    static var pendingUploadCount: Int {
        UserDefaults.standard.integer(forKey: pendingKey)
    }

    static func resetPendingUploadCount() {
        UserDefaults.standard.set(0, forKey: pendingKey)
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
