import Foundation
import Observation

/// 公网网关自签证书信任名单（任务 E，简单实现：只按主机名信任，不做证书指纹级校验）。
///
/// 接线（由主智能体完成）：GatewayWebSocket 目前用 URLSession.shared.webSocketTask 连接，
/// 无法拦截 TLS 挑战。需要把 GatewayWebSocket 改为持有带 URLSessionDelegate 的 URLSession，
/// 并在 `urlSession(_:didReceive:completionHandler:)` 中调用
/// `CertificateTrustStore.shared.shouldBypass(host:)`，命中信任名单则放行，否则按系统默认拒绝。
@MainActor
@Observable
final class CertificateTrustStore {
    static let shared = CertificateTrustStore()

    private let defaults = UserDefaults.standard
    private let key = "cert_trusted_hosts_v1"

    private(set) var trustedHosts: [String] = []

    private init() {
        trustedHosts = defaults.stringArray(forKey: key) ?? []
    }

    func isTrusted(_ host: String) -> Bool {
        let normalized = Self.normalizeHost(host)
        guard !normalized.isEmpty else { return false }
        return trustedHosts.contains(normalized)
    }

    @discardableResult
    func trust(_ host: String) -> Bool {
        let normalized = Self.normalizeHost(host)
        guard !normalized.isEmpty else { return false }
        if !trustedHosts.contains(normalized) {
            trustedHosts.append(normalized)
            persist()
        }
        return true
    }

    func untrust(_ host: String) {
        trustedHosts.removeAll { Self.normalizeHost($0) == Self.normalizeHost(host) }
        persist()
    }

    func clearAll() {
        trustedHosts.removeAll()
        persist()
    }

    /// 供 GatewayWebSocket 的 URLSession 挑战回调使用：host 在信任名单则放行。
    func shouldBypass(host: String?) -> Bool {
        guard let host else { return false }
        return isTrusted(host)
    }

    private func persist() {
        defaults.set(trustedHosts, forKey: key)
    }

    /// 从 URL 字符串提取规范化主机名（去掉 scheme/路径/端口后的 host）。
    static func host(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ||
           trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }
        guard let url = URL(string: candidate), let host = url.host else { return nil }
        return normalizeHost(host)
    }

    static func normalizeHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "wss://", with: "")
            .replacingOccurrences(of: "ws://", with: "")
            .components(separatedBy: "/").first ?? ""
    }
}