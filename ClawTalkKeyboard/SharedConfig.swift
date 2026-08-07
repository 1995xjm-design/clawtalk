import Foundation

/// 键盘扩展共享配置：从 App Group 读 ClawTalk 主 App 写入的网关配置。
///
/// 键名约定（联调阶段由 ClawTalk 写入侧补齐，本文件只负责读取）：
/// - gateway_url:   网关地址，如 https://192.168.1.10:18789
/// - gateway_token: 网关 Bearer token（与 ClawTalk 登录/设置一致）
/// - agent_id:      目标 OpenClaw agent，请求 model 拼成 "openclaw:<agentId>"
///
/// 读不到时返回空配置（isEmpty == true），调用方按未配置处理，不阻塞键盘输入。
struct SharedConfig {
    /// App Group 套件名，与 ClawTalkKeyboard.entitlements 保持一致
    static let appGroupID = AppConstants.appGroupId

    let gatewayURL: String
    let token: String
    let agentId: String

    /// 任一配置缺失即视为未配置
    var isEmpty: Bool {
        gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || agentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isConfigured: Bool { !isEmpty }

    /// 从 App Group 读取当前配置；读不到返回空配置
    static func load() -> SharedConfig {
        let defaults = UserDefaults(suiteName: appGroupID)
        return SharedConfig(
            gatewayURL: defaults?.string(forKey: Keys.gatewayURL) ?? "",
            token: defaults?.string(forKey: Keys.token) ?? "",
            agentId: defaults?.string(forKey: Keys.agentId) ?? ""
        )
    }

    /// App Group 键名（与 ClawTalk 写入侧约定）
    private enum Keys {
        static let gatewayURL = "gateway_url"
        static let token = "gateway_token"
        static let agentId = "agent_id"
    }
}