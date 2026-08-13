import Foundation

/// ClawTalk 隐私开关服务
/// 控制是否采集输入记录和剪贴板，状态持久化存储在 App Group UserDefaults
/// 默认值：采集开启（isCollectionEnabled = true）

public extension Notification.Name {
  /// 隐私采集状态变化通知（键盘眼睛按钮等 UI 刷新用）
  static let clawPrivacyDidChange = Notification.Name("clawTalk_privacy_did_change")
}
public final class ClawTalkPrivacyService {
  public static let shared = ClawTalkPrivacyService()

  private let defaults = UserDefaults(suiteName: HamsterConstants.appGroupName)
  private let key = "clawTalk_collection_enabled"

  /// 迁移旧 key（guru_collection_enabled → clawTalk_collection_enabled），一次性
  private func migrateLegacyKeyIfNeeded() {
    guard let defaults else { return }
    let legacyKey = "guru_collection_enabled"
    if defaults.object(forKey: legacyKey) != nil, defaults.object(forKey: key) == nil {
      defaults.set(defaults.bool(forKey: legacyKey), forKey: key)
      defaults.removeObject(forKey: legacyKey)
    }
  }

  /// 是否允许采集（true = 正常采集，false = 隐私模式暂停采集）
  public var isCollectionEnabled: Bool {
    get {
      migrateLegacyKeyIfNeeded()
      // object(forKey:) returns nil when key has never been set → default to true
      guard let stored = defaults?.object(forKey: key) else { return true }
      return (stored as? Bool) ?? true
    }
    set {
      defaults?.set(newValue, forKey: key)
    }
  }

  /// 切换采集状态，返回切换后的新值
  @discardableResult
  public func toggle() -> Bool {
    let next = !isCollectionEnabled
    isCollectionEnabled = next
    NotificationCenter.default.post(name: .clawPrivacyDidChange, object: nil)
    return next
  }
}
