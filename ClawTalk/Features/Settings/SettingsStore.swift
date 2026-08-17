import Foundation
import SwiftUI

@Observable
final class SettingsStore {
    private let defaults = UserDefaults.standard
    private let settingsKey = "app_settings"
    private let stableIDKey = "gateway_stable_id"
    // 官方对齐键：gateway.autoconnect / gateway.last.*（持久化连接意图与上次网关）
    private let autoConnectKey = "gateway.autoconnect"
    private let lastHostKey = "gateway.last.host"
    private let lastKindKey = "gateway.last.kind"
    private let lastPortKey = "gateway.last.port"
    private let lastTLSKey = "gateway.last.tls"
    private let secure = SecureStorage.shared

    var settings: AppSettings = .defaults

    var gatewayToken: String = "" {
        didSet {
            secure.gatewayToken = gatewayToken.isEmpty ? nil : gatewayToken
            syncGatewayToAppGroup()
        }
    }

    /// 网关 stableID（manual|host|port）：把设备令牌与具体网关绑定，换网关不串号。
    var gatewayStableID: String? {
        didSet { defaults.set(gatewayStableID, forKey: stableIDKey) }
    }

    var elevenLabsAPIKey: String = "" {
        didSet { secure.elevenLabsAPIKey = elevenLabsAPIKey.isEmpty ? nil : elevenLabsAPIKey }
    }

    var openAIAPIKey: String = "" {
        didSet { secure.openAIAPIKey = openAIAPIKey.isEmpty ? nil : openAIAPIKey }
    }

    var doubaoAPIKey: String = "" {
        didSet { secure.doubaoAPIKey = doubaoAPIKey.isEmpty ? nil : doubaoAPIKey }
    }

    var weatherAPIKey: String = "" {
        didSet { secure.weatherAPIKey = weatherAPIKey.isEmpty ? nil : weatherAPIKey }
    }

    var isConfigured: Bool {
        guard !settings.gatewayURL.isEmpty else { return false }
        let hasGatewayToken = !gatewayToken.isEmpty
        let hasBootstrapToken = settings.bootstrapToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        return hasGatewayToken || hasBootstrapToken
    }

    var hasCompletedOnboarding: Bool = false {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "has_completed_onboarding") }
    }

    init() {
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        }
        // bootstrapToken 迁移：旧版随 AppSettings JSON 落 UserDefaults，现改为仅存钥匙串（save() 同步）
        let legacyBootstrapToken = self.settings.bootstrapToken
        let storedBootstrapToken = secure.getString(SecureStorage.bootstrapTokenKey)
        if let storedBootstrapToken, !storedBootstrapToken.isEmpty {
            self.settings.bootstrapToken = storedBootstrapToken
        } else if let legacyBootstrapToken, !legacyBootstrapToken.isEmpty {
            secure.setString(legacyBootstrapToken, forKey: SecureStorage.bootstrapTokenKey)
            // 直接重写 UserDefaults JSON 清掉旧 token 字段（encode 已不写 bootstrapToken）；不调 save()，避免用空 gatewayToken 覆盖 App Group
            if let data = try? JSONEncoder().encode(self.settings) {
                defaults.set(data, forKey: settingsKey)
            }
        }
        self.gatewayToken = secure.gatewayToken ?? ""
        self.gatewayStableID = defaults.string(forKey: stableIDKey)
        self.elevenLabsAPIKey = secure.elevenLabsAPIKey ?? ""
        self.openAIAPIKey = secure.openAIAPIKey ?? ""
        self.doubaoAPIKey = secure.doubaoAPIKey ?? ""
        self.weatherAPIKey = secure.weatherAPIKey ?? ""
        self.hasCompletedOnboarding = defaults.bool(forKey: "has_completed_onboarding")

        // Auto-skip onboarding for existing configured users
        if isConfigured && !hasCompletedOnboarding {
            hasCompletedOnboarding = true
        }
    }

    /// 安全修改 settings：顶层赋值触发 @Observable 通知（直接改嵌套字段不会刷新 UI——壁纸/毛玻璃等「选了没反应」根因）。
    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        var updated = settings
        transform(&updated)
        settings = updated
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
        // bootstrapToken 只进钥匙串，不落 UserDefaults（encode 已排除该字段）
        let bootstrap = settings.bootstrapToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bootstrap, !bootstrap.isEmpty {
            secure.setString(bootstrap, forKey: SecureStorage.bootstrapTokenKey)
        } else {
            secure.setString(nil, forKey: SecureStorage.bootstrapTokenKey)
        }
        syncGatewayToAppGroup()
    }

    /// 官方对齐：启动时是否自动连接上次网关（gateway.autoconnect，默认 true）。
    var gatewayAutoConnect: Bool {
        get { defaults.object(forKey: autoConnectKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoConnectKey) }
    }

    /// 官方对齐：记录上次成功连接的网关（gateway.last.host/kind/port/tls）。
    var lastGatewayHost: String? {
        get { defaults.string(forKey: lastHostKey) }
        set { defaults.set(newValue, forKey: lastHostKey) }
    }
    var lastGatewayKind: String? {
        get { defaults.string(forKey: lastKindKey) }
        set { defaults.set(newValue, forKey: lastKindKey) }
    }
    var lastGatewayPort: Int {
        get { defaults.object(forKey: lastPortKey) as? Int ?? 0 }
        set { defaults.set(newValue, forKey: lastPortKey) }
    }
    var lastGatewayTLS: Bool {
        get { defaults.object(forKey: lastTLSKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: lastTLSKey) }
    }

    /// 安装号（官方 stable instance ID）：用于推送中继注册标识，与设备身份分离的安装级唯一标识。
    static func loadStableInstanceID() -> String? {
        if let existing = UserDefaults.standard.string(forKey: "push.installation.id"), !existing.isEmpty {
            return existing
        }
        let newID = UUID().uuidString.lowercased()
        UserDefaults.standard.set(newID, forKey: "push.installation.id")
        return newID
    }

    /// 连接成功后调用：把本次网关写入 gateway.last.*（官方键）。
    func recordLastGateway(urlString: String) {
        guard let components = URLComponents(string: urlString) else { return }
        lastGatewayHost = components.host
        lastGatewayPort = components.port ?? 0
        lastGatewayTLS = (components.scheme?.lowercased() == "https" || components.scheme?.lowercased() == "wss")
        lastGatewayKind = components.host?.contains(".") == true ? "remote" : "lan"
        gatewayAutoConnect = true
    }

    /// 应用扫码/粘贴/深链解析出的官方配对信息：写网关地址、令牌、bootstrapToken 与 stableID。
    func applyGatewayDeepLink(_ link: GatewayConnectDeepLink) {
        settings.gatewayURL = link.httpGatewayURL
        if let token = link.token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            gatewayToken = token
        }
        if let bootstrap = link.bootstrapToken, !bootstrap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.bootstrapToken = bootstrap
        }
        gatewayStableID = link.stableID
        settings.useWebSocket = true
        save()
    }

    /// 同步网关配置到 App Group（供键盘扩展读取）
    private func syncGatewayToAppGroup() {
        guard let groupDefaults = UserDefaults(suiteName: "group.7518554") else { return }
        groupDefaults.set(settings.gatewayURL, forKey: "gateway_url")
        groupDefaults.set(gatewayToken, forKey: "gateway_token")
        groupDefaults.set("main", forKey: "agent_id")
        // 语音助手通道与 DeepSeek Key 状态同步（键盘 AI 面板据此走统一通道）
        groupDefaults.set(voiceAgentChannelSyncValue, forKey: "voice_agent_channel")
        let hasDeepSeekKey = ((SecureStorage.shared.getString("deepseek_api_key") ?? "").isEmpty == false)
        groupDefaults.set(hasDeepSeekKey, forKey: "deepseek_configured")
        groupDefaults.synchronize()
    }

    /// 语音助手通道写入 App Group 的稳定英文标识（不用 rawValue：AppSettings 里是历史占位符）
    private var voiceAgentChannelSyncValue: String {
        switch settings.voiceAgentChannel {
        case .gateway: return "gateway"
        case .directDeepSeek: return "directDeepSeek"
        }
    }

}
