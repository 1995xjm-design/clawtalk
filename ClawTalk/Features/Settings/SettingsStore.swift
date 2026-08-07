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

    var isConfigured: Bool {
        !settings.gatewayURL.isEmpty && !gatewayToken.isEmpty
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
        guard let groupDefaults = UserDefaults(suiteName: "group.com.openclaw.clawtalk") else { return }
        groupDefaults.set(settings.gatewayURL, forKey: "gateway_url")
        groupDefaults.set(gatewayToken, forKey: "gateway_token")
        groupDefaults.set("main", forKey: "agent_id")
        groupDefaults.synchronize()
    }

}
