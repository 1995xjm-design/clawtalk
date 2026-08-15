import Foundation
import Observation

/// TLS 首次信任门（TOFU）：连接 wss 网关前，若主机不在证书信任名单，
/// 探测 TLS 指纹并弹窗让用户确认；确认后加入信任名单再继续连接。
/// 对齐官方 OpenClaw 的 GatewayTrustPromptAlert 流程（A5 再升级为指纹级 pinning）。
@MainActor
@Observable
final class TLSFingerprintGate {
    static let shared = TLSFingerprintGate()

    /// 待用户确认的信任弹窗（App 层观察并展示）。
    var pendingPrompt: TLSFingerprintPrompt?

    private var waiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var promptingHosts: Set<String> = []

    /// 信任弹窗无响应超时：超过该时长自动取消连接（防 ensureTrust 永久挂起）。
    private static let promptTimeoutSeconds: UInt64 = 60

    private init() {}

    /// 返回 true 表示可继续连接（主机已信任或用户已确认）。
    func ensureTrust(host: String, port: Int) async -> Bool {
        let normalized = normalizeHost(host)
        if CertificateTrustStore.shared.isTrusted(normalized) { return true }

        if !promptingHosts.contains(normalized) {
            promptingHosts.insert(normalized)
            let probe = TLSFingerprintProbe()
            await probe.probe(urlString: "wss://\(host):\(port)")
            pendingPrompt = TLSFingerprintPrompt(
                host: normalized,
                port: port,
                fingerprint: probe.result?.fingerprint
            )
        }

        return await withCheckedContinuation { continuation in
            waiters[normalized, default: []].append(continuation)
            // 超时兜底：弹窗无法呈现/用户长时间未操作时取消连接，避免永久挂起。
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.promptTimeoutSeconds * 1_000_000_000)
                self?.resolveTimeout(host: normalized)
            }
        }
    }

    /// 超时回调：取消该主机的所有等待连接（幂等，用户已确认时为无操作）。
    func resolveTimeout(host: String) {
        let normalized = normalizeHost(host)
        promptingHosts.remove(normalized)
        if pendingPrompt?.host == normalized {
            pendingPrompt = nil
        }
        let continuations = waiters.removeValue(forKey: normalized) ?? []
        for continuation in continuations {
            continuation.resume(returning: false)
        }
    }

    /// App 弹窗按钮回调：信任则加入信任名单，然后放行所有等待者。
    func resolve(host: String, trusted: Bool) {
        let normalized = normalizeHost(host)
        if trusted {
            CertificateTrustStore.shared.trust(normalized)
        }
        promptingHosts.remove(normalized)
        pendingPrompt = nil
        let continuations = waiters.removeValue(forKey: normalized) ?? []
        for continuation in continuations {
            continuation.resume(returning: trusted)
        }
    }

    private func normalizeHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// 信任弹窗数据（SwiftUI Alert item）。
struct TLSFingerprintPrompt: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let port: Int
    let fingerprint: String?
}
