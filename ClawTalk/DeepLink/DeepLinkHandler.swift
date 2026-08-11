import Foundation

/// 深链接处理：解析 clawtalk:// 链接（网关配对 / 打开频道）。
///
/// 支持格式：
/// - clawtalk://pair?gateway=https%3A%2F%2Fhost&token=xxx&setupCode=xxx
/// - clawtalk://connect?gateway=https%3A%2F%2Fhost&token=xxx
/// - clawtalk://open?channel=频道名
///
/// 接线（由主智能体在 ClawTalkApp 完成）：
/// 在 WindowGroup 根视图加 `.onOpenURL { url in DeepLinkHandler.handle(url, settings: settingsStore) }`，
/// 并把 clawtalk 加入 Info.plist 的 CFBundleURLTypes（URL Schemes = clawtalk）。
enum DeepLinkHandler {

    struct DeepLinkPayload: Equatable {
        enum Action: String {
            case pair = "pair"
            case connect = "connect"
            case open = "open"
        }

        let action: Action
        let gatewayURL: String?
        let token: String?
        let setupCode: String?
        let channelName: String?
        let rawURL: URL
    }

    static let scheme = "clawtalk"

    /// 解析 clawtalk:// 链接；无法识别时返回 nil。
    static func parse(_ url: URL) -> DeepLinkPayload? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              let actionRaw = components.host?.lowercased(),
              let action = DeepLinkPayload.Action(rawValue: actionRaw)
        else { return nil }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name] = value }
        }

        return DeepLinkPayload(
            action: action,
            gatewayURL: query["gateway"] ?? query["url"],
            token: query["token"],
            setupCode: query["setupCode"] ?? query["setup_code"],
            channelName: query["channel"] ?? query["channelName"],
            rawURL: url
        )
    }

    /// 处理链接并写入设置；返回是否已处理。
    /// - pair/connect：写入网关地址与令牌（setupCode 作为令牌兜底），并跳过新手引导
    /// - open：仅解析，返回 channelName 是否存在，由调用方负责选中频道
    @discardableResult
    static func handle(_ url: URL, settings: SettingsStore) -> Bool {
        guard let payload = parse(url) else { return false }

        switch payload.action {
        case .pair, .connect:
            var changed = false
            if let gateway = payload.gatewayURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !gateway.isEmpty {
                settings.settings.gatewayURL = gateway
                changed = true
            }
            let token = (payload.token ?? payload.setupCode)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let token, !token.isEmpty {
                settings.gatewayToken = token
                changed = true
            }
            if changed {
                // 通过深链接配对说明用户有意配置，跳过新手引导
                settings.hasCompletedOnboarding = true
                settings.save()
            }
            return true

        case .open:
            return payload.channelName != nil
        }
    }
}