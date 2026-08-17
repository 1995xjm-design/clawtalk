import Foundation

/// 引导页连接模式（官方对齐 OnboardingConnectionMode）。
enum OnboardingConnectionMode: String, CaseIterable {
    case homeNetwork = "home_network"
    case remoteDomain = "remote_domain"
    case developerLocal = "developer_local"

    var title: String {
        switch self {
        case .homeNetwork: return "家庭网络"
        case .remoteDomain: return "远程域名"
        case .developerLocal: return "本机开发"
        }
    }
}

/// 引导页状态存储（官方对齐 OnboardingStateStore）。
/// 键与官方一致：onboarding.completed / onboarding.first_run_intro_seen /
/// onboarding.last_mode / onboarding.last_success_time（我方 OnboardingView 已在用同一批键）。
enum OnboardingStateStore {
    private static let completedDefaultsKey = "onboarding.completed"
    private static let firstRunIntroSeenDefaultsKey = "onboarding.first_run_intro_seen"
    private static let lastModeDefaultsKey = "onboarding.last_mode"
    private static let lastSuccessTimeDefaultsKey = "onboarding.last_success_time"

    /// 启动时是否应展示引导页（等价官方：已完成 / 已有存档网关 / 已配置网关服务器 → 不展示）。
    static func shouldPresentOnLaunch(
        defaults: UserDefaults = .standard,
        hasSavedGatewayConnection: Bool? = nil)
        -> Bool
    {
        if defaults.bool(forKey: Self.completedDefaultsKey) { return false }
        let hasSaved = hasSavedGatewayConnection ?? Self.hasPersistedGatewayConnection(defaults: defaults)
        if hasSaved { return false }
        return !Self.hasConfiguredGatewayServer(defaults: defaults)
    }

    static func markCompleted(mode: OnboardingConnectionMode? = nil, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Self.completedDefaultsKey)
        if let mode {
            defaults.set(mode.rawValue, forKey: Self.lastModeDefaultsKey)
        }
        defaults.set(Int(Date().timeIntervalSince1970), forKey: Self.lastSuccessTimeDefaultsKey)
    }

    static func shouldPresentFirstRunIntro(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: Self.firstRunIntroSeenDefaultsKey)
    }

    static func markFirstRunIntroSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Self.firstRunIntroSeenDefaultsKey)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: Self.completedDefaultsKey)
        defaults.set(false, forKey: Self.firstRunIntroSeenDefaultsKey)
    }

    static func lastMode(defaults: UserDefaults = .standard) -> OnboardingConnectionMode? {
        let raw = defaults.string(forKey: Self.lastModeDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return OnboardingConnectionMode(rawValue: raw)
    }

    /// 等价官方 GatewaySettingsStore.activeGatewayEntry()：存在上次网关主机或已保存网关 URL。
    private static func hasPersistedGatewayConnection(defaults: UserDefaults) -> Bool {
        if let host = defaults.string(forKey: "gateway.last.host"), !host.isEmpty { return true }
        if let url = defaults.string(forKey: "gateway_url"), !url.isEmpty { return true }
        if let groupDefaults = UserDefaults(suiteName: "group.7518554"),
           let url = groupDefaults.string(forKey: "gateway_url"),
           !url.isEmpty
        {
            return true
        }
        return false
    }

    /// 等价官方 appModel.gatewayServerName：当前是否已持有有效网关服务器配置。
    private static func hasConfiguredGatewayServer(defaults: UserDefaults) -> Bool {
        if let host = defaults.string(forKey: "gateway.last.host"), !host.isEmpty { return true }
        return false
    }
}
