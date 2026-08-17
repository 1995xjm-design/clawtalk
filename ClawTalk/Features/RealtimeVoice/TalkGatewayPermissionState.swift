import Foundation

/// 网关语音权限状态（对齐官方 TalkGatewayPermissionState）：
/// 记录网关注册的实时语音 provider 与权限级别。
enum TalkGatewayPermissionState {
    static let storageKey = "talk.gateway.permission"

    enum Level: String, Codable {
        case none
        case limited
        case full
    }

    struct Snapshot: Codable {
        var level: Level
        var provider: String?
        var updatedAtMs: Double
    }

    static func load() -> Snapshot? {
        guard let raw = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: raw)
    }

    static func save(_ snapshot: Snapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    static func setFull(provider: String?) {
        save(Snapshot(level: .full, provider: provider, updatedAtMs: Date().timeIntervalSince1970 * 1000))
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
