import Foundation

// MARK: - 键盘本地配置存储
// 绕过 App Group 的独立配置通道：
// 免费 Apple ID 签名不支持 App Groups entitlement，
// 键盘扩展在自己的沙盒 UserDefaults 里保存网关配置，
// SharedConfig.load() 优先读本地、读不到再回落 App Group。
class KeyboardConfigStore {

    static let shared = KeyboardConfigStore()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let gatewayURL = "kb_local_gateway_url"
        static let token = "kb_local_gateway_token"
        static let agentId = "kb_local_agent_id"
    }

    private init() {}

    // MARK: - 读写

    var gatewayURL: String {
        get { defaults.string(forKey: Keys.gatewayURL) ?? "" }
        set { defaults.set(newValue, forKey: Keys.gatewayURL) }
    }

    var token: String {
        get { defaults.string(forKey: Keys.token) ?? "" }
        set { defaults.set(newValue, forKey: Keys.token) }
    }

    var agentId: String {
        get { defaults.string(forKey: Keys.agentId) ?? "" }
        set { defaults.set(newValue, forKey: Keys.agentId) }
    }

    /// 是否已配置本地网关
    var isConfigured: Bool {
        !gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !agentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 保存一组配置（三个字段一起写，保证一致性）
    func save(gatewayURL: String, token: String, agentId: String) {
        self.gatewayURL = gatewayURL
        self.token = token
        self.agentId = agentId
    }

    /// 清除本地配置（回落到 App Group / 未配置状态）
    func clear() {
        defaults.removeObject(forKey: Keys.gatewayURL)
        defaults.removeObject(forKey: Keys.token)
        defaults.removeObject(forKey: Keys.agentId)
    }
}
