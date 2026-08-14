import Foundation
import Observation

/// 网关档案：一组网关地址 + 令牌，支持多网关切换（任务 D）。
/// 为遵守「不动 AppSettings.swift」约束，档案独立持久化在 UserDefaults；
/// 令牌单独写入 iOS 钥匙串（SecureStorage），不随档案 JSON 落盘。
/// 切换时把激活档案写入 SettingsStore 的 gatewayURL/gatewayToken（全局唯一入口）。
struct GatewayProfile: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var url: String
    /// 令牌仅内存持有，持久化走 SecureStorage（见 GatewayProfileStore）
    var token: String
    var note: String?

    init(id: UUID = UUID(), name: String, url: String, token: String = "", note: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.token = token
        self.note = note
    }

    // MARK: - Codable（不落盘 token）

    enum CodingKeys: String, CodingKey {
        case id, name, url, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        token = "" // 从钥匙串补全（GatewayProfileStore.loadTokens）
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

/// 多网关档案存储（@MainActor @Observable，可在 SwiftUI 中直接观察）。
@MainActor
@Observable
final class GatewayProfileStore {
    static let shared = GatewayProfileStore()

    private let defaults = UserDefaults.standard
    private let secure = SecureStorage.shared
    private let profilesKey = "gateway_profiles_v1"
    private let activeKey = "gateway_profile_active_id"

    private(set) var profiles: [GatewayProfile] = []
    private(set) var activeProfileID: UUID?

    var activeProfile: GatewayProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    init() {
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([GatewayProfile].self, from: data) {
            profiles = decoded
        }
        loadTokens()
        if let raw = defaults.string(forKey: activeKey), let id = UUID(uuidString: raw) {
            activeProfileID = id
        }
        migrateLegacyIfNeeded()
    }

    /// 从钥匙串补全每个档案的令牌。
    private func loadTokens() {
        for index in profiles.indices {
            profiles[index].token = secure.getString(tokenKey(profiles[index].id)) ?? ""
        }
    }

    /// 旧版单网关配置（SettingsStore.gatewayURL）首次迁移为一个档案。
    private func migrateLegacyIfNeeded() {
        guard profiles.isEmpty else { return }
        let settings = SettingsStore()
        let url = settings.settings.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let profile = GatewayProfile(name: "默认网关", url: url, token: settings.gatewayToken)
        profiles = [profile]
        activeProfileID = profile.id
        secure.setString(profile.token, forKey: tokenKey(profile.id))
        persist()
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String, url: String, token: String, note: String? = nil, activate: Bool = false) -> GatewayProfile {
        let profile = GatewayProfile(name: name, url: url, token: token, note: note)
        profiles.append(profile)
        secure.setString(profile.token, forKey: tokenKey(profile.id))
        if activate || profiles.count == 1 {
            activeProfileID = profile.id
        }
        persist()
        return profile
    }

    func update(_ profile: GatewayProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        secure.setString(profile.token, forKey: tokenKey(profile.id))
        persist()
    }

    func delete(_ profile: GatewayProfile) {
        profiles.removeAll { $0.id == profile.id }
        secure.setString(nil, forKey: tokenKey(profile.id))
        if activeProfileID == profile.id {
            activeProfileID = profiles.first?.id
        }
        persist()
    }

    /// 切换当前激活网关：写入 SettingsStore（gatewayURL/gatewayToken）供全局使用。
    func activate(_ profile: GatewayProfile, settings: SettingsStore) {
        activeProfileID = profile.id
        persist()
        settings.settings.gatewayURL = profile.url.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.gatewayToken = profile.token
        settings.save()
    }

    // MARK: - Persistence

    private func tokenKey(_ id: UUID) -> String {
        "gateway_token_profile_\(id.uuidString)"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: profilesKey)
        }
        defaults.set(activeProfileID?.uuidString, forKey: activeKey)
        // 网关档案数据变化：通知主 App 刷新小组件（WidgetDataSync 单入口模式）
        NotificationCenter.default.post(name: WidgetDataSync.dataDidChangeNotification, object: nil)
    }
}