import Foundation

/// 统一错误文本本地化：按系统语言返回中文/英文文案。
/// 所有错误出口（聊天/测试连接/网络/键盘等）统一走这里，避免英文漏网。
enum AppErrorText {
    private static var isChinese: Bool {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return lang.hasPrefix("zh")
    }

    /// 把原始错误文本映射成本地化文案；识别不到时原样返回（保真不误翻）。
    static func localized(_ raw: String) -> String {
        let lower = raw.lowercased()

        // 设备未批准 / 配对
        if lower.contains("pairing required") || lower.contains("device is not approved") || lower.contains("not approved") {
            return isChinese
                ? "设备未获批准：请在 OpenClaw 网关侧批准此设备后再试。"
                : "Device not approved: approve this device in the OpenClaw gateway first."
        }
        // 令牌
        if lower.contains("unauthorized") || lower.contains("invalid token")
            || (lower.contains("token") && (lower.contains("invalid") || lower.contains("expired"))) {
            return isChinese
                ? "网关令牌无效或已过期：请在设置中重新填写网关令牌。"
                : "Invalid or expired gateway token: update it in Settings."
        }
        // HTTPS
        if lower.contains("insecure") || (lower.contains("https") && (lower.contains("plain") || lower.contains("http"))) {
            return isChinese
                ? "必须使用 HTTPS：请在设置中更新网关地址（本机/内网地址可例外）。"
                : "HTTPS required: update the gateway URL in Settings (local addresses may be an exception)."
        }
        // 连接失败
        if lower.contains("connection refused") || lower.contains("connection closed")
            || lower.contains("network is unreachable") || lower.contains("cannot connect")
            || lower.contains("connect failed") {
            return isChinese
                ? "无法连接网关：请检查网络和网关地址，确认 OpenClaw 正在运行。"
                : "Cannot reach the gateway: check your network and gateway URL, and make sure OpenClaw is running."
        }
        // DNS
        if lower.contains("cannot find host") || lower.contains("dns") || lower.contains("failed host lookup") {
            return isChinese
                ? "无法解析网关地址（DNS）：请检查网关地址是否正确。"
                : "Cannot resolve the gateway address (DNS): check the gateway URL."
        }
        // 超时
        if lower.contains("timed out") || lower.contains("timeout") {
            return isChinese
                ? "连接网关超时：请检查网络后重试。"
                : "Gateway connection timed out: check your network and retry."
        }
        // 网关返回错误响应（连错网关/路径）
        if lower.contains("bad server response") || lower.contains("unexpected response") {
            return isChinese
                ? "网关返回了错误响应：请检查网关地址是否为 OpenClaw 网关（端口 18789），WebSocket 路径保持 /ws，不要填成后端 18890"
                : "Gateway returned an unexpected response: make sure the gateway URL points to OpenClaw (port 18789) and the WebSocket path is /ws, not the backend 18890."
        }
        // 麦克风不可用
        if lower.contains("osstatus") {
            return isChinese
                ? "麦克风不可用：请检查 iOS 麦克风权限，或关闭正在占用麦克风的其他应用"
                : "Microphone unavailable: check iOS microphone permission, or close other apps using the microphone."
        }

        // URL 无效
        if lower.contains("invalid url") || lower.contains("bad url") || lower.contains("malformed url") {
            return isChinese
                ? "网关地址无效：请在设置中检查网关地址。"
                : "Invalid gateway URL: check it in Settings."
        }
        // EXT 扩展错误
        if lower.contains("ext:") {
            return isChinese ? "网关返回扩展错误（EXT）：\(raw)" : "Gateway returned an EXT error: \(raw)"
        }
        return raw
    }

    /// HTTP 状态码映射
    static func httpStatus(_ code: Int) -> String {
        switch code {
        case 401, 403:
            return isChinese
                ? "认证失败（HTTP \(code)）：请检查网关令牌。"
                : "Authentication failed (HTTP \(code)): check the gateway token."
        case 404:
            return isChinese
                ? "网关地址错误（HTTP 404）：请检查网关地址。"
                : "Gateway URL not found (HTTP 404): check the gateway URL."
        case 408, 429:
            return isChinese
                ? "请求超时或触发限流（HTTP \(code)）：请稍后重试。"
                : "Request timed out or rate-limited (HTTP \(code)): retry later."
        case 400...499:
            return isChinese
                ? "网关请求错误（HTTP \(code)）：请检查网关配置。"
                : "Gateway request error (HTTP \(code)): check the gateway config."
        case 500...599:
            return isChinese
                ? "网关服务器错误（HTTP \(code)）：请稍后重试。"
                : "Gateway server error (HTTP \(code)): retry later."
        default:
            return isChinese
                ? "网关返回错误（HTTP \(code)）"
                : "Gateway returned HTTP \(code)"
        }
    }
}
