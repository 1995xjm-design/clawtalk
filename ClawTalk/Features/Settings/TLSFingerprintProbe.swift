import CryptoKit
import Foundation
import Network
import Observation
import Security
import SwiftUI

/// TLS 指纹探测（「连接与状态」功能组）。
///
/// 对网关地址发起 TLS 连接（Network.framework），抓取服务器叶证书 DER，
/// 计算 SHA256 指纹，并与 CertificateTrustStore 信任名单比对，
/// UI 显示「已信任 / 未信任 / 指纹」，可一键加入/移出信任名单。
struct TLSFingerprintResult: Equatable, Sendable {
    let host: String
    let fingerprint: String
    let isTrusted: Bool
    let validFrom: Date?
    let validTo: Date?
    let errorMessage: String?
    let serverName: String?
}

@MainActor
@Observable
final class TLSFingerprintProbe {

    private(set) var result: TLSFingerprintResult?
    private(set) var isProbing = false
    private(set) var lastError: String?

    /// 对网关地址做 TLS 探测。urlString 可为 https://host:port 或 host:port（自动补 https）。
    func probe(urlString: String) async {
        isProbing = true
        lastError = nil
        result = nil
        defer { isProbing = false }

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "未配置网关地址"
            return
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("ws://") {
            lastError = "当前网关配置为 HTTP 明文（无 TLS），无法探测 TLS 指纹。请改用 https:// 或 wss:// 地址。"
            return
        }

        var candidate = trimmed
        if candidate.hasPrefix("wss://") {
            candidate = "https://" + candidate.dropFirst(6)
        } else if !candidate.contains("://") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), let host = url.host else {
            lastError = "网关地址无法解析"
            return
        }
        let port = url.port ?? 443

        let capture = TrustCapture()
        let tlsOptions = NWProtocolTLS.Options()
        // 允许任意证书完成握手（仅用于抓取指纹，不影响 App 真实连接策略）
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions) { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            capture.set(Self.extract(from: trust, host: host))
            complete(true)
        }
        let parameters = NWParameters(tls: tlsOptions)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            lastError = "端口无效：\(port)"
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)

        let outcome: TrustCapture.Outcome = await withCheckedContinuation { continuation in
            var didResume = false
            let lock = NSLock()
            func resumeOnce(_ value: TrustCapture.Outcome) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.captured(capture.get()))
                    connection.cancel()
                case .failed(let error):
                    resumeOnce(.failed(error.localizedDescription))
                case .cancelled:
                    resumeOnce(.captured(capture.get()))
                default:
                    break
                }
            }
            let queue = DispatchQueue(label: "clawtalk.tls-probe")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) {
                resumeOnce(.timedOut)
                connection.cancel()
            }
        }
        connection.cancel()

        switch outcome {
        case .captured(let captured):
            guard let captured else {
                lastError = "TLS 握手完成但未取到服务器证书"
                return
            }
            result = TLSFingerprintResult(
                host: captured.host,
                fingerprint: captured.fingerprint,
                isTrusted: CertificateTrustStore.shared.isTrusted(captured.host),
                validFrom: captured.validFrom,
                validTo: captured.validTo,
                errorMessage: nil,
                serverName: captured.serverName
            )
        case .failed(let message):
            lastError = "TLS 连接失败：\(message)"
        case .timedOut:
            lastError = "TLS 连接超时（4 秒内未完成握手）"
        }
    }

    // MARK: - 证书解析

    /// 从 SecTrust 提取叶证书指纹与有效期（在 verify block 中执行，不触碰 MainActor 状态）。
    nonisolated fileprivate static func extract(from trust: SecTrust, host: String) -> TrustCapture.CapturedTrust? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        let derData = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: derData)
        let fingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        let validity = validity(of: leaf)
        let summary = SecCertificateCopySubjectSummary(leaf) as String?
        return TrustCapture.CapturedTrust(
            host: host,
            fingerprint: fingerprint,
            validFrom: validity.from,
            validTo: validity.to,
            serverName: summary
        )
    }

    /// iOS 上无法直接读证书有效期字段（SecCertificateCopyValues 为 macOS-only），
    /// 此处诚实返回 nil；有效期展示区域会随之隐藏。
    nonisolated static func validity(of certificate: SecCertificate) -> (from: Date?, to: Date?) {
        _ = certificate
        return (nil, nil)
    }
}

/// 从 verify block 线程安全地带回证书数据。
private final class TrustCapture: @unchecked Sendable {
    enum Outcome {
        case captured(CapturedTrust?)
        case failed(String)
        case timedOut
    }

    struct CapturedTrust {
        let host: String
        let fingerprint: String
        let validFrom: Date?
        let validTo: Date?
        let serverName: String?
    }

    private let lock = NSLock()
    private var stored: CapturedTrust?

    func set(_ value: CapturedTrust?) {
        lock.lock()
        defer { lock.unlock() }
        stored = value
    }

    func get() -> CapturedTrust? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// TLS 指纹页：显示当前网关的证书指纹与信任状态。
/// 由主智能体接入设置页（如「网关」区的 NavigationLink）。
struct TLSFingerprintProbeView: View {
    let settings: SettingsStore

    @State private var probe = TLSFingerprintProbe()
    @State private var trustStore = CertificateTrustStore.shared

    private var gatewayURL: String {
        settings.settings.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            Section("网关地址") {
                Text(gatewayURL.isEmpty ? "未配置网关" : gatewayURL)
                    .foregroundStyle(gatewayURL.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }

            Section {
                Button {
                    startProbe()
                } label: {
                    HStack(spacing: 8) {
                        if probe.isProbing {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("正在探测…")
                        } else {
                            Label("开始 TLS 指纹探测", systemImage: "lock.shield")
                        }
                    }
                }
                .disabled(gatewayURL.isEmpty || probe.isProbing)
            } footer: {
                Text("对当前网关发起 TLS 连接并抓取服务器证书指纹。仅 https/wss 地址支持 TLS 指纹。")
            }

            if let result = probe.result {
                Section("证书指纹") {
                    LabeledContent("握手主机", value: result.host)
                    if let serverName = result.serverName, !serverName.isEmpty {
                        LabeledContent("证书名称", value: serverName)
                    }
                    Text(result.fingerprint)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    if let validFrom = result.validFrom, let validTo = result.validTo {
                        LabeledContent("有效期", value: "\(Self.shortDate(validFrom)) ~ \(Self.shortDate(validTo))")
                    }
                }

                Section("信任状态") {
                    LabeledContent("状态", content: {
                        Label(
                            result.isTrusted ? "已信任" : "未信任",
                            systemImage: result.isTrusted ? "checkmark.shield.fill" : "shield.slash"
                        )
                        .foregroundStyle(result.isTrusted ? .green : .orange)
                    })

                    if result.isTrusted {
                        Button("取消信任此主机", role: .destructive) {
                            trustStore.untrust(result.host)
                            startProbe()
                        }
                    } else {
                        Button("信任此主机") {
                            trustStore.trust(result.host)
                            startProbe()
                        }
                    }
                } footer: {
                    Text("加入信任名单后，网关连接（GatewayWebSocket）会放行该主机的自签证书，与 App 实际连接策略一致。")
                }
            }

            if let lastError = probe.lastError {
                Section {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("TLS 指纹")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func startProbe() {
        Task {
            await probe.probe(urlString: gatewayURL)
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
