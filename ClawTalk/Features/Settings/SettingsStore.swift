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
        self.gatewayToken = secure.gatewayToken ?? ""
        self.elevenLabsAPIKey = secure.elevenLabsAPIKey ?? ""
        self.openAIAPIKey = secure.openAIAPIKey ?? ""
        self.doubaoAPIKey = secure.doubaoAPIKey ?? ""
        self.hasCompletedOnboarding = defaults.bool(forKey: "has_completed_onboarding")

        // Auto-skip onboarding for existing configured users
        if isConfigured && !hasCompletedOnboarding {
            hasCompletedOnboarding = true
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        syncGatewayToAppGroup()
        }
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
