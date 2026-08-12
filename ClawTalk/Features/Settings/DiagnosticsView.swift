import Darwin
import Network
import SwiftUI

/// 日志与诊断：查看本地错误日志，复制，并同步到电脑端 OpenClaw 分析原因和解决方法。
struct DiagnosticsView: View {
    let settings: SettingsStore
    @State private var logs: [LogCollector.Entry] = []
    @State private var isSyncing = false
    @State private var resultText: String?
    @State private var syncError: String?
    @State private var isSendingToFiles = false
    @State private var filesMessage: String?
    @State private var filesError: String?
    @State private var diagnosis: ConnectionDiagnostics.Result?
    @State private var isDiagnosing = false

    private var logText: String {
        LogCollector.load()
            .reversed()
            .map { "[\($0.module)] \(Self.fmt($0.timestamp)) \($0.message)" }
            .joined(separator: "\n")
    }

    var body: some View {
        List {
            Section {
                Button {
                    runDiagnostics()
                } label: {
                    HStack(spacing: 6) {
                        if isDiagnosing {
                            ProgressView()
                            Text("诊断中…（约需 15 秒）")
                        } else {
                            Label("一键诊断", systemImage: "stethoscope")
                        }
                        Spacer()
                        if let diagnosis, !isDiagnosing {
                            Image(systemName: diagnosis.allPassed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(diagnosis.allPassed ? .green : .orange)
                        }
                    }
                }
                .disabled(isDiagnosing)

                if let diagnosis {
                    ForEach(diagnosis.steps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.symbol)
                                .foregroundStyle(step.color)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(step.step.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(Self.durationText(step.durationMs))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("一键诊断")
            } footer: {
                Text("串行执行：DNS 解析 → 端口连通 → TLS 握手 → WebSocket 连接 → HTTP 鉴权。")
            }

            if let diagnosis, !diagnosis.allPassed {
                Section("修复建议") {
                    ForEach(diagnosis.suggestions, id: \.self) { suggestion in
                        Text("• \(suggestion)")
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
            Section {
                Button {
                    syncToOpenClaw()
                } label: {
                    if isSyncing {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("正在同步…")
                        }
                    } else {
                        Label("同步到 OpenClaw", systemImage: "arrow.up.circle")
                    }
                }
                .disabled(isSyncing || settings.settings.gatewayURL.isEmpty)

                Button {
                    sendLogsToFileTransfer()
                } label: {
                    if isSendingToFiles {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("正在发送…")
                        }
                    } else {
                        Label("发送到文件传输助手", systemImage: "paperplane")
                    }
                }
                .disabled(isSendingToFiles || settings.settings.gatewayURL.isEmpty)

                Button("复制全部") {
                    UIPasteboard.general.string = logText
                }
            } header: {
                Text("操作")
            } footer: {
                Text("把错误日志发送到电脑端 OpenClaw（会进入「日志诊断」频道），让它分析原因和给出解决方法，可回到该频道继续追问。")
            }

            if let resultText {
                Section("OpenClaw 分析") {
                    Text(resultText)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            if let syncError {
                Section {
                    Text(syncError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if let filesMessage {
                Section("发送结果") {
                    Text(filesMessage)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            if let filesError {
                Section {
                    Text(filesError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("最近日志") {
                if logs.isEmpty {
                    Text("暂无日志")
                        .foregroundStyle(.secondary)
                }
                ForEach(logs) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.module)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.openClawRed)
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                NavigationLink {
                    ConnectionHealthMonitorView(settings: settings)
                } label: {
                    Label("连接健康监控", systemImage: "waveform.path.ecg")
                }
            } header: {
                Text("健康监控")
            } footer: {
                Text("每 30 秒检测一次网关 /health，记录成功率/延迟/断连次数，并展示最近 24 小时趋势；状态变化会发本地通知。")
            }
        }
        .navigationTitle("日志与诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            logs = LogCollector.load().reversed()
        }
    }

    private func syncToOpenClaw() {
        guard !settings.settings.gatewayURL.isEmpty else {
            syncError = "请先配置网关地址和令牌。"
            return
        }
        isSyncing = true
        syncError = nil
        resultText = nil
        InstructionChannels.ensureChannel(name: "日志诊断", systemEmoji: "🩺", sessionKey: InstructionChannels.diagnostics)
        let text = logText
        let instruction = "请分析以下 ClawTalk 客户端错误日志，逐条说明可能的原因和解决方法，用简体中文回复，最后给一个总结：\n\n" + text

        let gw = settings.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Task {
            do {
                let reply = try await OpenClawClient().chat(
                    messages: [Message(role: .user, content: instruction)],
                    gatewayURL: gw,
                    token: settings.gatewayToken,
                    sessionKey: InstructionChannels.diagnostics
                )
                isSyncing = false
                resultText = reply
            } catch {
                isSyncing = false
                syncError = "同步失败：\(AppErrorText.localized(error.localizedDescription))"
            }
        }
    }

    /// 导出日志为带时间戳的 txt，复用文件传输助手上传接口（POST /upload）发送到电脑端 inbound。
    private func sendLogsToFileTransfer() {
        guard !settings.settings.gatewayURL.isEmpty else {
            filesError = "请先配置网关地址和令牌。"
            return
        }
        isSendingToFiles = true
        filesMessage = nil
        filesError = nil

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "clawtalk-logs-\(formatter.string(from: Date())).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let text = logText.isEmpty ? "（暂无日志）" : logText
        do {
            try text.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            isSendingToFiles = false
            filesError = "日志导出失败：\(AppErrorText.localized(error.localizedDescription))"
            return
        }

        let transfer = FileTransferViewModel(settings: settings)
        Task {
            let ok = await transfer.uploadFile(fileURL: tempURL, suggestedName: name)
            isSendingToFiles = false
            try? FileManager.default.removeItem(at: tempURL)
            if ok {
                filesMessage = "已发送到电脑 inbound（\(name)）"
            } else {
                filesError = transfer.errorMessage ?? "发送失败，请确认电脑端文件服务已启动。"
            }
        }
    }

    private func runDiagnostics() {
        isDiagnosing = true
        diagnosis = nil
        Task {
            let result = await ConnectionDiagnostics.run(settings: settings)
            diagnosis = result
            isDiagnosing = false
        }
    }

    private static func durationText(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
    }

    private static func fmt(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - 一键诊断

/// 一键诊断：串行执行 DNS 解析 → 端口连通 → TLS 握手 → WebSocket 连接 → HTTP 鉴权 五项检查。
struct ConnectionDiagnostics {

    enum Step: String, CaseIterable, Identifiable {
        case dns = "DNS 解析"
        case port = "端口连通"
        case tls = "TLS 握手"
        case webSocket = "WebSocket 连接"
        case auth = "HTTP 鉴权"

        var id: String { rawValue }
    }

    struct StepResult: Identifiable {
        let id = UUID()
        let step: Step
        let success: Bool
        let durationMs: Int
        let detail: String

        var symbol: String { success ? "checkmark.circle.fill" : "xmark.circle.fill" }
        var color: Color { success ? .green : .red }
    }

    struct Result {
        let steps: [StepResult]
        let suggestions: [String]
        let finishedAt: Date

        var allPassed: Bool { steps.allSatisfy(\.success) }
    }

    /// 目标地址解析：scheme / host / port。
    struct TargetInfo {
        let rawURL: String
        let scheme: String
        let host: String
        let port: Int
        let isIP: Bool

        init(rawURL: String) {
            self.rawURL = rawURL
            var candidate = rawURL
            var scheme = ""
            if let range = rawURL.range(of: "://") {
                scheme = String(rawURL[..<range.lowerBound]).lowercased()
            } else if !rawURL.isEmpty {
                candidate = "https://\(rawURL)"
                scheme = "https"
            }
            var port = 0
            var host = ""
            if let url = URL(string: candidate), let urlHost = url.host {
                host = urlHost
                port = url.port ?? (scheme == "http" ? 80 : 443)
            }
            self.scheme = scheme
            self.host = host
            self.port = port
            self.isIP = Self.isIPv4(host)
        }

        static func isIPv4(_ host: String) -> Bool {
            var address = in_addr()
            return host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
        }
    }

    static func run(settings: SettingsStore) async -> Result {
        let rawURL = settings.settings.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = TargetInfo(rawURL: rawURL)
        var steps: [StepResult] = []

        steps.append(await runDNS(target: target))
        steps.append(await runPort(target: target))
        steps.append(await runTLS(target: target))
        steps.append(await runWebSocket(settings: settings))
        steps.append(await runAuth(settings: settings))

        let suggestions = Self.suggestions(for: steps, configured: !rawURL.isEmpty)
        if suggestions.count > 1 || suggestions.first?.hasPrefix("全部通过") != true {
            let failed = steps.filter { !$0.success }.map { $0.step.rawValue }
            if !failed.isEmpty {
                LogCollector.record(module: "连接诊断", "一键诊断：\(failed.joined(separator: "、"))")
            }
        }
        return Result(steps: steps, suggestions: suggestions, finishedAt: Date())
    }

    // MARK: 各检查项

    static func runDNS(target: TargetInfo) async -> StepResult {
        let start = Date()
        guard !target.host.isEmpty else { return step(.dns, success: false, since: start, detail: "未配置网关地址") }
        if target.isIP {
            return step(.dns, success: true, since: start, detail: "主机已是 IP 地址（\(target.host)），无需解析")
        }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(target.host, nil, &hints, &result)
        defer { if let result { freeaddrinfo(result) } }

        guard code == 0, let result else {
            let message = gai_strerror(code).map { String(cString: $0) } ?? "未知错误"
            return step(.dns, success: false, since: start, detail: "解析失败：\(message)")
        }

        var resolved = "解析成功"
        if let addr = result.pointee.ai_addr {
            var address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var resolvedAddress = ""
            buffer.withUnsafeMutableBufferPointer { ptr in
                if let base = ptr.baseAddress, inet_ntop(AF_INET, &address.sin_addr, base, socklen_t(INET_ADDRSTRLEN)) != nil {
                    resolvedAddress = String(cString: base)
                }
            }
            if !resolvedAddress.isEmpty {
                resolved = resolvedAddress
            }
        }
        return step(.dns, success: true, since: start, detail: "\(target.host) → \(resolved)")
    }

    static func runPort(target: TargetInfo) async -> StepResult {
        let start = Date()
        guard !target.host.isEmpty else { return step(.port, success: false, since: start, detail: "未配置网关地址") }
        guard target.port > 0 else { return step(.port, success: false, since: start, detail: "无法解析端口") }
        let open = await tcpConnect(host: target.host, port: target.port, timeout: 4)
        return step(.port, success: open, since: start, detail: open ? "\(target.host):\(target.port) 可连通" : "\(target.host):\(target.port) 无法连通（超时或拒绝）")
    }

    static func runTLS(target: TargetInfo) async -> StepResult {
        let start = Date()
        guard !target.host.isEmpty else { return step(.tls, success: false, since: start, detail: "未配置网关地址") }
        let usesTLS = target.scheme == "https" || target.scheme == "wss"
        guard usesTLS else {
            return step(.tls, success: true, since: start, detail: "网关配置为 \(target.scheme.isEmpty ? "未指定" : target.scheme.uppercased()) 明文，未启用 TLS")
        }

        let delegate = DiagnosticsTLSDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 4
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://\(target.host):\(target.port)/") else {
            return step(.tls, success: false, since: start, detail: "TLS 地址无法解析")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        do {
            _ = try await session.data(for: request)
            return step(.tls, success: true, since: start, detail: "TLS 握手成功")
        } catch {
            return step(.tls, success: false, since: start, detail: friendlyTLSMessage(error))
        }
    }

    static func runWebSocket(settings: SettingsStore) async -> StepResult {
        let start = Date()
        let wsURLString = settings.settings.resolvedWebSocketURL
        guard !wsURLString.isEmpty, let wsURL = URL(string: wsURLString) else {
            return step(.webSocket, success: false, since: start, detail: "WebSocket 地址无效，请先配置网关并开启 WebSocket 模式")
        }

        let delegate = DiagnosticsTLSDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: wsURL)
        task.resume()
        do {
            _ = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask { try await task.receive() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    task.cancel(with: .goingAway, reason: nil)
                    throw StepError.timeout("等待网关消息超时")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            return step(.webSocket, success: true, since: start, detail: "WebSocket 已连接并收到网关消息")
        } catch {
            return step(.webSocket, success: false, since: start, detail: "连接失败：\(AppErrorText.localized(error.localizedDescription))")
        }
    }

    static func runAuth(settings: SettingsStore) async -> StepResult {
        let start = Date()
        let base = settings.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return step(.auth, success: false, since: start, detail: "未配置网关地址") }
        // 二维码配对后网关下发 device token（存 Keychain），优先取它；回退手填令牌。
        let resolvedToken = OpenClawClient.resolveHTTPToken(
            settingsToken: settings.gatewayToken,
            gatewayURL: settings.settings.gatewayURL
        )
        guard !resolvedToken.isEmpty else {
            return step(.auth, success: false, since: start, detail: "未获取到网关令牌（请先 openclaw qr 配对或填写令牌）")
        }
        guard let url = URL(string: "\(base)/health") else {
            return step(.auth, success: false, since: start, detail: "网关地址无法解析")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("Bearer \(resolvedToken)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return step(.auth, success: true, since: start, detail: "鉴权通过（HTTP \(status)）")
            case 401, 403:
                return step(.auth, success: false, since: start, detail: "令牌被拒绝（HTTP \(status)）——请检查网关令牌或重新配对")
            case 404:
                return step(.auth, success: true, since: start, detail: "网关可达（HTTP 404：无 /health 接口，鉴权未验证）")
            default:
                return step(.auth, success: false, since: start, detail: "网关返回 HTTP \(status)")
            }
        } catch {
            return step(.auth, success: false, since: start, detail: "请求失败：\(AppErrorText.localized(error.localizedDescription))")
        }
    }

    // MARK: 工具

    static func step(_ step: Step, success: Bool, since start: Date, detail: String) -> StepResult {
        StepResult(step: step, success: success, durationMs: Int(Date().timeIntervalSince(start) * 1000), detail: detail)
    }

    static func tcpConnect(host: String, port: Int, timeout: TimeInterval) async -> Bool {
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
            let queue = DispatchQueue(label: "clawtalk.diagnostics.tcp")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                resumeOnce(false)
                connection.cancel()
            }
        }
    }

    static func friendlyTLSMessage(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasBadDate:
            return "TLS 握手失败：服务器证书不受系统信任（自签证书）。可到「TLS 指纹」页查看指纹并加入信任名单。"
        default:
            return "TLS 握手失败：\(AppErrorText.localized(error.localizedDescription))"
        }
    }

    static func suggestions(for steps: [StepResult], configured: Bool) -> [String] {
        guard configured else {
            return ["未配置网关：请先在设置中填写网关地址与令牌，或使用「自动发现」查找局域网网关。"]
        }
        var hints: [String] = []
        for step in steps where !step.success {
            switch step.step {
            case .dns:
                hints.append("DNS 解析失败：检查网关地址拼写与当前网络（与网关在同一 Wi-Fi/局域网）。")
            case .port:
                hints.append("端口无法连通：确认网关已启动、手机与网关在同一网络，且防火墙放行 18789 端口。")
            case .tls:
                hints.append("TLS 握手失败：自签证书需先在「TLS 指纹」页查看指纹并加入信任名单；或改用 https/wss 地址。")
            case .webSocket:
                hints.append("WebSocket 连接失败：确认已开启 WebSocket 模式、网关版本支持协议 3–4，且网络可达。")
            case .auth:
                hints.append("鉴权被拒绝：检查网关令牌，或重新运行 openclaw qr 配对。")
            }
        }
        return hints.isEmpty ? ["全部通过：网关连接正常。"] : hints
    }
}

/// 与 App 一致的 TLS 放行策略：信任名单内主机放行自签证书，否则走系统默认。
private final class DiagnosticsTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        Task { @MainActor in
            let bypass = CertificateTrustStore.shared.shouldBypass(host: host)
            if bypass, let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}

private enum StepError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let message): return message
        }
    }
}

