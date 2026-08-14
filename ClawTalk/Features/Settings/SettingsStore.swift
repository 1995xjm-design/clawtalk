import Foundation
import SwiftUI

@Observable
final class SettingsStore {
    private let defaults = UserDefaults.standard
    private let settingsKey = "app_settings"
    private let secure = SecureStorage.shared

    var settings: AppSettings = .defaults

    var gatewayToken: String = "" {
        didSet {
            secure.gatewayToken = gatewayToken.isEmpty ? nil : gatewayToken
            syncGatewayToAppGroup()
        }
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
