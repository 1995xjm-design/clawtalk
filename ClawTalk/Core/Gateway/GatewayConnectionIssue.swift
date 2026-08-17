import Foundation

/// 网关连接问题分类（对齐官方 GatewayConnectionIssue / GatewayProblemView）：
/// 三类样式：配对类（时钟黄）/ 网络超时类（wifi 黄）/ 设备身份签名类（锁盾红）。
enum GatewayConnectionIssueKind: Equatable {
    case pairing
    case network
    case identity
    case unknown

    var symbol: String {
        switch self {
        case .pairing: return "clock.badge.exclamationmark"
        case .network: return "wifi.exclamationmark"
        case .identity: return "lock.shield"
        case .unknown: return "questionmark.circle"
        }
    }

    var isError: Bool { self == .identity || self == .unknown }
}

struct GatewayConnectionIssue: Equatable {
    var kind: GatewayConnectionIssueKind
    var title: String
    var detail: String
    var requestID: String?
    var repairCommand: String?

    /// 从连接错误文本分类（登录链路兜底：未知错误也给出可操作提示）。
    static func classify(error: String?, requestID: String? = nil) -> GatewayConnectionIssue {
        let message = error ?? ""
        let lower = message.lowercased()
        if lower.contains("pairing") || lower.contains("approve") || lower.contains("配对") || lower.contains("批准") {
            return GatewayConnectionIssue(
                kind: .pairing,
                title: "需要网关批准这台设备",
                detail: "配对请求等待网关批准。请在电脑上运行 openclaw devices approve 批准后重试。",
                requestID: requestID,
                repairCommand: "openclaw devices approve"
            )
        }
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("超时")
            || lower.contains("cannot connect") || lower.contains("无法连接") || lower.contains("network") {
            return GatewayConnectionIssue(
                kind: .network,
                title: "无法连接网关",
                detail: "网关地址可能不可达。请检查网络、网关地址与端口，或重新扫码配对。",
                requestID: requestID,
                repairCommand: nil
            )
        }
        if lower.contains("tls") || lower.contains("certificate") || lower.contains("证书") || lower.contains("指纹") {
            return GatewayConnectionIssue(
                kind: .identity,
                title: "设备身份或证书校验失败",
                detail: "网关 TLS 证书或设备身份无法验证。请确认证书信任或重新配对。",
                requestID: requestID,
                repairCommand: nil
            )
        }
        return GatewayConnectionIssue(
            kind: .unknown,
            title: "连接出现问题",
            detail: message.isEmpty ? "未知错误，请查看日志与诊断。" : message,
            requestID: requestID,
            repairCommand: nil
        )
    }
}