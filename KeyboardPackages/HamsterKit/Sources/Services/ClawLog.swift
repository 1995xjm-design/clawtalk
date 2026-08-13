import Foundation

/// 键盘侧错误日志工具：写入 App Group（group.7518554）的 app_error_logs，
/// 与主 App LogCollector 共用同一份数据，让「日志与诊断」能看到键盘扩展错误。
/// 只记录错误/异常（与主 App LogCollector 语义一致），os_log/Logger 调试日志保留不变。
public enum ClawLog {
  private static let appGroupSuiteName = "group.7518554"
  private static let key = "app_error_logs"
  private static let limit = 100

  private static let writeQueue = DispatchQueue(label: "com.clawtalk.kb.log", qos: .utility)

  /// App Group 共享存储；套件初始化失败时回退 standard（不丢日志能力）。
  private static var defaults: UserDefaults {
    UserDefaults(suiteName: appGroupSuiteName) ?? .standard
  }

  /// 与主 App LogCollector.Entry 字段一致（默认 JSON 日期策略，双向可解）。
  struct Entry: Codable {
    let id: UUID
    let timestamp: Date
    let module: String
    let message: String
    var appVersion: String?
  }

  /// 当前扩展版本号（如 1.2.2(5)）；读不到返回空串。
  static var currentVersion: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    if short.isEmpty && build.isEmpty { return "" }
    return short.isEmpty ? "(\(build))" : build.isEmpty ? short : "\(short)(\(build))"
  }

  /// 记录一条错误日志。module 如「键盘」「键盘面板」「键盘数据」「键盘AI」「键盘OCR」「键盘语音」「键盘建议」「键盘洞察」。
  public static func record(module: String, _ message: String) {
    writeQueue.async {
      var entries = load()
      entries.append(Entry(id: UUID(), timestamp: Date(), module: module, message: message, appVersion: currentVersion))
      if entries.count > limit {
        entries.removeFirst(entries.count - limit)
      }
      if let data = try? JSONEncoder().encode(entries) {
        defaults.set(data, forKey: key)
      }
    }
  }

  private static func load() -> [Entry] {
    guard let data = defaults.data(forKey: key),
          let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
    return entries
  }
}
