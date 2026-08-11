import Darwin
import Foundation
import Network
import Observation
import SwiftUI

/// 网关自动发现（「连接与状态」功能组）。
///
/// 方案（OpenClaw 无 mDNS 时的简化版）：
/// 1. Bonjour 尽力尝试 `_openclaw._tcp`（网关/电脑端广播了 mDNS 时直接命中）；
/// 2. 对本机所在 /24 网段做常见端口（默认 18789）逐主机探测：
///    - TCP 可连通 → 标记「端口开放」；
///    - TCP 连通且 HTTP GET /health 有响应 → 标记「疑似网关」；
///    - /health 返回 2xx 且内容含 ok/openclaw → 标记「已确认 OpenClaw 网关」。
///
/// 结果按确认度排序，UI 上点击「使用」即可把地址填回设置/引导页。
struct GatewayCandidate: Identifiable, Equatable, Sendable {
    enum Confidence: String, Equatable, Sendable {
        case confirmed = "已确认 OpenClaw 网关"
        case mdns = "mDNS 发现"
        case httpOpen = "疑似网关（/health 有响应）"
        case portOpen = "端口开放（无 HTTP 响应）"

        var rank: Int {
            switch self {
            case .confirmed: return 0
            case .mdns: return 1
            case .httpOpen: return 2
            case .portOpen: return 3
            }
        }
    }

    let id: UUID
    let host: String
    let port: Int
    let scheme: String
    let confidence: Confidence
    let healthStatus: String?
    let latencyMs: Double?

    /// 可直接填入设置页的网关地址（按 http 探测；公网/需要 TLS 时由接线方自行切换 https）。
    var displayURL: String {
        "\(scheme)://\(host):\(port)"
    }
}

/// 扫描器：获取本机 IP → 生成 /24 候选 → 并发探测 → 汇总排序。
@MainActor
@Observable
final class GatewayAutoDiscovery {

    private(set) var candidates: [GatewayCandidate] = []
    private(set) var isScanning = false
    private(set) var scannedCount = 0
    private(set) var totalCandidates = 0
    private(set) var lastScanError: String?
    private(set) var localIPs: [String] = []

    static let defaultPorts = [18789]
    private static let tcpTimeoutSeconds: TimeInterval = 1.0
    private static let httpTimeoutSeconds: TimeInterval = 1.5
    private static let batchSize = 32

    init() {
        localIPs = Self.localIPv4Addresses()
    }

    // MARK: - 主入口

    /// 扫描同网段网关。ports 默认只扫 OpenClaw 网关默认端口 18789。
    func startScan(ports: [Int] = defaultPorts) async {
        guard !isScanning else { return }
        isScanning = true
        lastScanError = nil
        candidates = []
        scannedCount = 0
        totalCandidates = 0
        defer { isScanning = false }

        // 1) mDNS 尽力尝试（失败不影响主扫描）
        let mdnsCandidates = await Self.browseOpenClawServices(timeout: 2.5)

        // 2) /24 网段逐主机探测
        let hosts = Self.subnetHosts(localIPs: localIPs)
        guard !hosts.isEmpty else {
            lastScanError = "未获取到本机局域网 IP，请确认已连接 Wi-Fi。"
            return
        }

        var probes: [(host: String, port: Int)] = []
        for host in hosts {
            for port in ports {
                probes.append((host, port))
            }
        }
        totalCandidates = probes.count

        let counter = ScanProgress(total: probes.count)
        let results = await withTaskGroup(of: GatewayCandidate?.self) { group -> [GatewayCandidate] in
            var collected: [GatewayCandidate] = []
            var batchStart = 0
            while batchStart < probes.count {
                let batchEnd = min(batchStart + Self.batchSize, probes.count)
                for probe in probes[batchStart..<batchEnd] {
                    group.addTask {
                        let candidate = await Self.probeCandidate(host: probe.host, port: probe.port)
                        await counter.tick()
                        let done = await counter.done
                        await MainActor.run { self.scannedCount = done }
                        return candidate
                    }
                }
                for await candidate in group {
                    if let candidate {
                        collected.append(candidate)
                    }
                }
                batchStart = batchEnd
            }
            return collected
        }

        candidates = Self.merge(mdns: mdnsCandidates, scanned: results)
    }

    // MARK: - 探测

    /// 单个候选：先 TCP 连通，再 HTTP GET /health 确认。
    nonisolated static func probeCandidate(host: String, port: Int) async -> GatewayCandidate? {
        let tcpOpen = await tcpConnect(host: host, port: port, timeout: tcpTimeoutSeconds)
        guard tcpOpen else { return nil }

        let start = Date()
        guard let url = URL(string: "http://\(host):\(port)/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = httpTimeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let latencyMs = Date().timeIntervalSince(start) * 1000
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            let is2xx = (200..<300).contains(status)
            let looksLikeOpenClaw = body.contains("ok") || body.contains("openclaw") || body.contains("claw")
            let confidence: GatewayCandidate.Confidence = (is2xx && looksLikeOpenClaw) ? .confirmed : .httpOpen
            let health = "HTTP \(status) · \(latencyText(latencyMs))"
            return GatewayCandidate(
                id: UUID(),
                host: host,
                port: port,
                scheme: "http",
                confidence: confidence,
                healthStatus: health,
                latencyMs: latencyMs
            )
        } catch {
            let latencyMs = Date().timeIntervalSince(start) * 1000
            return GatewayCandidate(
                id: UUID(),
                host: host,
                port: port,
                scheme: "http",
                confidence: .portOpen,
                healthStatus: "TCP 已连通，/health 无响应",
                latencyMs: latencyMs
            )
        }
    }

    /// TCP 连通性探测（Network.framework，短超时）。
    nonisolated static func tcpConnect(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            var didResume = false
            let lock = NSLock()
            func resumeOnce(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(true)
                    connection.cancel()
                case .failed:
                    resumeOnce(false)
                    connection.cancel()
                case .cancelled:
                    resumeOnce(false)
                default:
                    break
                }
            }
            let queue = DispatchQueue(label: "clawtalk.discovery.tcp")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                resumeOnce(false)
                connection.cancel()
            }
        }
    }

    // MARK: - 汇总

    /// 合并 mDNS 与扫描结果：同一 host:port 保留确认度更高的。
    nonisolated static func merge(mdns: [GatewayCandidate], scanned: [GatewayCandidate]) -> [GatewayCandidate] {
        var byKey: [String: GatewayCandidate] = [:]
        for candidate in mdns + scanned {
            let key = "\(candidate.host):\(candidate.port)"
            if let existing = byKey[key] {
                if candidate.confidence.rank < existing.confidence.rank {
                    byKey[key] = candidate
                }
            } else {
                byKey[key] = candidate
            }
        }
        return byKey.values.sorted { lhs, rhs in
            if lhs.confidence.rank != rhs.confidence.rank {
                return lhs.confidence.rank < rhs.confidence.rank
            }
            return lhs.host < rhs.host
        }
    }

    // MARK: - 本机 IP 与 /24 候选

    nonisolated static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddresses) == 0 else { return [] }
        defer { freeifaddrs(interfaceAddresses) }

        var cursor = interfaceAddresses
        while let current = cursor {
            let family = current.pointee.ifa_addr?.pointee.sa_family
            if family == sa_family_t(AF_INET), let addressPointer = current.pointee.ifa_addr {
                var address = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var ip = ""
                buffer.withUnsafeMutableBufferPointer { ptr in
                    if let base = ptr.baseAddress, inet_ntop(AF_INET, &address.sin_addr, base, socklen_t(INET_ADDRSTRLEN)) != nil {
                        ip = String(cString: base)
                    }
                }
                if !ip.isEmpty && !ip.hasPrefix("127.") {
                    addresses.append(ip)
                }
            }
            cursor = current.pointee.ifa_next
        }
        return addresses
    }

    /// 生成 /24 网段候选（1~254，排除本机地址）。
    nonisolated static func subnetHosts(localIPs: [String]) -> [String] {
        guard let local = localIPs.first(where: { isPrivateIPv4($0) }) ?? localIPs.first else { return [] }
        let parts = local.split(separator: ".")
        guard parts.count == 4, let lastOctet = Int(parts[3]) else { return [] }
        let prefix = parts[0...2].joined(separator: ".")
        return (1...254).map { "\(prefix).\($0)" }.filter { $0 != local }
    }

    nonisolated static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        if first == 10 { return true }
        if first == 192 && second == 168 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        return false
    }

    // MARK: - Bonjour（mDNS）

    /// 尽力尝试发现 `_openclaw._tcp` 服务；无 mDNS 时返回空数组（不影响 /24 扫描）。
    nonisolated static func browseOpenClawServices(timeout: TimeInterval) async -> [GatewayCandidate] {
        await withCheckedContinuation { continuation in
            let browser = OpenClawBonjourBrowser()
            browser.onFinish = { services in
                let candidates = services.compactMap { service -> GatewayCandidate? in
                    guard let ip = firstIPv4Address(in: service.addresses ?? []) else { return nil }
                    let port = service.port > 0 ? Int(service.port) : defaultPorts[0]
                    return GatewayCandidate(
                        id: UUID(),
                        host: ip,
                        port: port,
                        scheme: "http",
                        confidence: .mdns,
                        healthStatus: "Bonjour 服务：\(service.name)",
                        latencyMs: nil
                    )
                }
                continuation.resume(returning: candidates)
            }
            browser.startSearching(timeout: timeout)
        }
    }

    nonisolated static func firstIPv4Address(in dataList: [Data]) -> String? {
        for data in dataList {
            let ip = data.withUnsafeBytes { raw -> String? in
                guard let baseAddress = raw.bindMemory(to: sockaddr.self).baseAddress else { return nil }
                if baseAddress.pointee.sa_family == sa_family_t(AF_INET) {
                    var address = raw.bindMemory(to: sockaddr_in.self).baseAddress!.pointee
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var ip = ""
                    buffer.withUnsafeMutableBufferPointer { ptr in
                        if let base = ptr.baseAddress, inet_ntop(AF_INET, &address.sin_addr, base, socklen_t(INET_ADDRSTRLEN)) != nil {
                            ip = String(cString: base)
                        }
                    }
                    return ip.isEmpty ? nil : ip
                }
                return nil
            }
            if let ip {
                return ip
            }
        }
        return nil
    }

    nonisolated static func latencyText(_ ms: Double) -> String {
        ms < 1 ? "<1ms" : "\(Int(ms.rounded()))ms"
    }
}

/// 扫描进度（跨并发任务计数）。
private actor ScanProgress {
    private(set) var done = 0
    let total: Int

    init(total: Int) {
        self.total = total
    }

    func tick() {
        done += 1
    }
}

/// Bonjour 浏览器：搜索 `_openclaw._tcp`，超时后回调已解析的服务。
private final class OpenClawBonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onFinish: (([NetService]) -> Void)?

    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var didFinish = false

    func startSearching(timeout: TimeInterval) {
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.schedule(in: .main, forMode: .default)
        browser.searchForServices(ofType: "_openclaw._tcp", inDomain: "")
        self.browser = browser

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.schedule(in: .main, forMode: .default)
        service.resolve(withTimeout: 2)
        services.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // 单个服务解析失败可忽略
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        browser?.delegate = nil
        browser?.stop()
        let resolved = services
        onFinish?(resolved)
        onFinish = nil
    }
}

/// 自动发现页：引导页/设置页通过 NavigationLink 或 sheet 打开，
/// 点击「使用」通过 onSelect 把发现的网关地址填回输入框。
struct GatewayAutoDiscoveryView: View {
    let knownGatewayURL: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scanner = GatewayAutoDiscovery()
    @State private var hasScanned = false

    private var currentGatewayNormalized: String {
        knownGatewayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await scan() }
                } label: {
                    HStack(spacing: 8) {
                        if scanner.isScanning {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("正在扫描…")
                        } else {
                            Label("开始扫描", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        Spacer()
                        if scanner.isScanning {
                            Text("\(scanner.scannedCount)/\(scanner.totalCandidates)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(scanner.isScanning)

                if !scanner.localIPs.isEmpty {
                    LabeledContent("本机 IP", value: scanner.localIPs.joined(separator: "、"))
                }

                if let lastScanError = scanner.lastScanError {
                    Text(lastScanError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("自动发现")
            } footer: {
                Text("手机与网关需在同一局域网。扫描方式：Bonjour mDNS（_openclaw._tcp）+ 同网段 /24 逐主机探测 18789 端口。")
            }

            Section("发现结果") {
                if hasScanned && !scanner.isScanning && scanner.candidates.isEmpty {
                    Text("未发现网关。请确认：网关已启动、手机与电脑在同一 Wi-Fi、网关防火墙放行 18789 端口。")
                        .foregroundStyle(.secondary)
                }

                ForEach(scanner.candidates) { candidate in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(candidate.host)
                                    .font(.subheadline.weight(.semibold))
                                if candidate.displayURL == currentGatewayNormalized {
                                    Text("当前")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                            }
                            Text("端口 \(candidate.port) · \(candidate.confidence.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let health = candidate.healthStatus {
                                Text(health)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if let latency = candidate.latencyMs {
                            Text(GatewayAutoDiscovery.latencyText(latency))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button("使用") {
                            onSelect(candidate.displayURL)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("自动发现网关")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func scan() async {
        hasScanned = true
        await scanner.startScan()
    }
}
