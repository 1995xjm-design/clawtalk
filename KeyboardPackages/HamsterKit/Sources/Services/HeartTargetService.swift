import Foundation
import UIKit

extension Notification.Name {
  /// 聊天对象档案集合变化（增删改/切换选中）
  public static let heartTargetProfilesDidChange = Notification.Name("heartTargetProfilesDidChange")
}

/// 聊天对象个人档案（设置页加入，键盘面板内切换）
public struct HeartTargetProfile: Codable, Identifiable, Equatable {
  public let id: UUID
  public var name: String
  public var bio: String
  public var avatarData: Data?

  public init(id: UUID = UUID(), name: String = "", bio: String = "", avatarData: Data? = nil) {
    self.id = id
    self.name = name
    self.bio = bio
    self.avatarData = avatarData
  }

  /// 头像 UIImage（用于设置页与键盘面板展示）
  public var avatarImage: UIImage? {
    guard let avatarData else { return nil }
    return UIImage(data: avatarData)
  }

  public var displayName: String {
    name.isEmpty ? "未命名档案" : name
  }
}

/// 聊天对象档案存储服务（UserDefaults，App Group 与键盘扩展共享）
public class HeartTargetService {
  public static let shared = HeartTargetService()

  private let defaults = UserDefaults(suiteName: HamsterConstants.appGroupName)
  private let profilesKey = "heart_target_profiles"
  private let selectedKey = "heart_target_selected"

  public private(set) var profiles: [HeartTargetProfile] = []
  public private(set) var selectedIndex: Int = -1

  public var selectedProfile: HeartTargetProfile? {
    guard selectedIndex >= 0, selectedIndex < profiles.count else { return nil }
    return profiles[selectedIndex]
  }

  public var hasProfiles: Bool { !profiles.isEmpty }

  init() {
    reload()
  }

  func reload() {
    if let data = defaults?.data(forKey: profilesKey),
       let decoded = try? JSONDecoder().decode([HeartTargetProfile].self, from: data) {
      profiles = decoded
    }
    selectedIndex = defaults?.integer(forKey: selectedKey) ?? -1
    if selectedIndex >= profiles.count { selectedIndex = -1 }
  }

  private func persist() {
    defaults?.set(try? JSONEncoder().encode(profiles), forKey: profilesKey)
    defaults?.set(selectedIndex, forKey: selectedKey)
    NotificationCenter.default.post(name: .heartTargetProfilesDidChange, object: nil)
  }

  @discardableResult
  public func upsert(_ profile: HeartTargetProfile) -> HeartTargetProfile {
    if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[idx] = profile
    } else {
      profiles.append(profile)
      if selectedIndex < 0 { selectedIndex = 0 }
    }
    persist()
    return profile
  }

  public func delete(id: UUID) {
    profiles.removeAll { $0.id == id }
    if selectedIndex >= profiles.count { selectedIndex = profiles.isEmpty ? -1 : profiles.count - 1 }
    persist()
  }

  public func select(at index: Int) {
    guard index >= 0, index < profiles.count else { return }
    selectedIndex = index
    persist()
  }

  public func select(id: UUID) {
    if let idx = profiles.firstIndex(where: { $0.id == id }) {
      select(at: idx)
    }
  }
}