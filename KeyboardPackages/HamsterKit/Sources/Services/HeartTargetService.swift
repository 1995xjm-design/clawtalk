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
  /// 长记忆（聊天/OCR 截图沉淀，按时间戳前缀追加，去重）
  public var memories: [String]

  public init(id: UUID = UUID(), name: String = "", bio: String = "", avatarData: Data? = nil, memories: [String]? = nil) {
    self.id = id
    self.name = name
    self.bio = bio
    self.avatarData = avatarData
    self.memories = memories ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, bio, avatarData, memories
  }

  /// Codable 兼容：旧数据缺 memories 字段时解码为空数组，不破坏已有档案。
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    bio = try container.decodeIfPresent(String.self, forKey: .bio) ?? ""
    avatarData = try container.decodeIfPresent(Data.self, forKey: .avatarData)
    memories = try container.decodeIfPresent([String].self, forKey: .memories) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(bio, forKey: .bio)
    try container.encodeIfPresent(avatarData, forKey: .avatarData)
    try container.encode(memories, forKey: .memories)
  }

  /// 头像 UIImage（用于设置页与键盘面板展示）
  public var avatarImage: UIImage? {
    guard let avatarData else { return nil }
    return UIImage(data: avatarData)
  }

  public var displayName: String {
    name.isEmpty ? "未命名档案" : name
  }

  /// 追加一条长记忆：时间戳前缀 + 去重 + 上限 200 条（超出丢最旧）。
  public mutating func appendMemory(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // 去重：忽略已有条目的时间戳前缀后比较正文
    if memories.contains(where: { $0.hasSuffix(trimmed) }) { return }
    let stamp = Self.memoryTimestampFormatter.string(from: Date())
    memories.append("\(stamp) \(trimmed)")
    if memories.count > 200 {
      memories.removeFirst(memories.count - 200)
    }
  }

  private static let memoryTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()
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

  /// 追加长记忆到指定档案（未找到档案返回 false，静默失败）。
  @discardableResult
  public func appendMemory(to profileId: UUID, _ text: String) -> Bool {
    guard let index = profiles.firstIndex(where: { $0.id == profileId }) else { return false }
    var profile = profiles[index]
    profile.appendMemory(text)
    profiles[index] = profile
    persist()
    return true
  }
}
