import Foundation
import OSLog
import UIKit

/// TLS 挑战回调：主机在证书信任名单（CertificateTrustStore）内则放行自签证书，否则走系统默认校验。
private final class GatewayTLSDelegate: NSObject, URLSessionDelegate {
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

/// Gateway WebSocket transport actor.
///
/// Handles connection lifecycle, v3 handshake with Ed25519 device identity,
/// RPC request/response with continuation-based waiting, server push events,
/// keepalive pings, tick monitoring, and automatic reconnection with backoff.
///
/// Ported from OpenClawKit's GatewayChannelActor, streamlined for ClawTalk.
actor GatewayWebSocket {

    // MARK: - Types

    /// Server-push messages from the gateway.
    enum Push: Sendable {
        case snapshot(HelloOk)
        case event(EventFrame)
        case seqGap(expected: Int, received: Int)
    }

    /// Connection state observable from outside the actor.
    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
    }

    enum GatewayError: LocalizedError {
        case connectFailed(String)
        case requestTimeout(String)
        case responseError(method: String, code: String, message: String)
        case notConnected
        case encodingFailed
        case pairingRequired(requestId: String?)
        case bootstrapTokenInvalid

        var errorDescription: String? {
            switch self {
            case .connectFailed(let msg): return "连接失败：\(msg)"
            case .requestTimeout(let method): return "\(method) 请求超时"
            case .responseError(let method, let code, let msg): return "\(method)：[\(code)] \(msg)"
            case .notConnected: return "未连接到网关"
            case .encodingFailed: return "请求编码失败"
            case .pairingRequired: return "设备未配对：请在 OpenClaw 网关管理端批准配对请求，App 将自动重试连接"
            case .bootstrapTokenInvalid: return "配对码无效或已过期，请重新运行 openclaw qr 并扫码"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.openclaw.clawtalk", category: "gateway-ws")

    // TLS 会话（带 URLSessionDelegate）：信任名单内主机放行自签证书
    private let tlsDelegate: GatewayTLSDelegate
    private let session: URLSession

    private var wsTask: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<GatewayFrame, Error>] = [:]
    private var isConnected = false
    private var isConnecting = false
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    private var url: URL
    private var token: String?
    private var bootstrapToken: String?
    private var password: String?
    private var shouldReconnect = true
    private var backoffMs: Double = 2000
    private var lastSeq: Int?
    /// Gateway advertised RPC methods from HelloOk features["methods"] (official GatewayNodeSession.serverMethods).
    private var serverMethods: Set<String>?
    private var lastTick: Date?
    private var tickIntervalMs: Double = 30000
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // Timeouts
    private let connectTimeoutSeconds: Double = 30
    private let challengeTimeoutSeconds: Double = 6
    private let keepaliveIntervalSeconds: Double = 15
    private let defaultRequestTimeoutMs: Double = 15000

    // Background tasks
    private var watchdogTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?

    // Callbacks
    private let pushHandler: (@Sendable (Push) async -> Void)?
    private let deviceTokenHandler: (@Sendable (String) -> Void)?
    private let stateHandler: (@Sendable (ConnectionState) async -> Void)?

    // Connect options
    private let role: String
    private let scopes: [String]
    private let caps: [String]
    private let commands: [String]
    private let permissions: [String: Bool]
    private let displayName: String
    private let clientMode: String

    // MARK: - Init

    init(
        url: URL,
        token: String?,
        bootstrapToken: String? = nil,
        password: String? = nil,
        role: String = "operator",
        scopes: [String] = ["operator.admin", "operator.read", "operator.write", "operator.approvals", "operator.questions", "operator.pairing", "operator.talk.secrets"],
        caps: [String] = [],
        commands: [String] = [],
        permissions: [String: Bool] = [:],
        displayName: String = "ClawTalk",
        clientMode: String = "ui",
        pushHandler: (@Sendable (Push) async -> Void)? = nil,
        stateHandler: (@Sendable (ConnectionState) async -> Void)? = nil,
        deviceTokenHandler: (@Sendable (String) -> Void)? = nil
    ) {
        self.url = url
        self.token = token
        self.bootstrapToken = bootstrapToken
        self.password = password
        self.role = role
        self.scopes = scopes
        self.caps = caps
        self.commands = commands
        self.permissions = permissions
        self.displayName = displayName
        self.clientMode = clientMode
        self.pushHandler = pushHandler
        self.stateHandler = stateHandler
        self.deviceTokenHandler = deviceTokenHandler

        let tlsDelegate = GatewayTLSDelegate()
        self.tlsDelegate = tlsDelegate
        self.session = URLSession(configuration: .default, delegate: tlsDelegate, delegateQueue: nil)

        Task { [weak self] in
            await self?.startWatchdog()
        }
    }

    // MARK: - Public API

    /// Connect to the gateway. Safe to call multiple times — coalesces concurrent calls.
    func connect() async throws {
        if isConnected, wsTask?.state == .running { return }

        if isConnecting {
            try await withCheckedThrowingContinuation { cont in
                connectWaiters.append(cont)
            }
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        wsTask?.cancel(with: .goingAway, reason: nil)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024 // 16 MB
        wsTask = task
        task.resume()

        await stateHandler?(.connecting)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.performHandshake() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.connectTimeoutSeconds * 1_000_000_000))
                    // Cancel the WebSocket task to unblock any pending receive() calls,
                    // otherwise the task group hangs waiting for the cancelled child to finish.
                    await self.cancelWebSocketTask()
                    throw GatewayError.connectFailed("连接超时")
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            isConnected = false
            wsTask?.cancel(with: .goingAway, reason: nil)
            await stateHandler?(.disconnected)
            let waiters = connectWaiters
            connectWaiters.removeAll()
            for w in waiters { w.resume(throwing: error) }
            logger.error("gateway connect failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        listen()
        isConnected = true
        backoffMs = 2000
        lastSeq = nil
        startKeepalive()
        await stateHandler?(.connected)

        let waiters = connectWaiters
        connectWaiters.removeAll()
        for w in waiters { w.resume(returning: ()) }
    }

    /// Whether the server advertised support for the given RPC method.
    /// Returns nil when no snapshot has been received yet (official supportsServerMethod).
    func supportsServerMethod(_ method: String) -> Bool? {
        serverMethods?.contains(method)
    }

    /// 健康探测：最近收到网关 tick 事件则视为健康（对齐官方 GatewayHealthMonitor 心跳语义）。
    func pingHealth(timeoutSeconds: Double = 5) async -> Bool {
        guard let lastTick else { return false }
        let maxAge = (tickIntervalMs / 1000.0) * 2.0 + timeoutSeconds
        return Date().timeIntervalSince(lastTick) <= maxAge
    }

    /// Shut down the connection. Does not auto-reconnect.
    func shutdown() async {
        shouldReconnect = false
        isConnected = false
        serverMethods = nil
        watchdogTask?.cancel(); watchdogTask = nil
        tickTask?.cancel(); tickTask = nil
        keepaliveTask?.cancel(); keepaliveTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil); wsTask = nil
        session.invalidateAndCancel()
        await stateHandler?(.disconnected)

        let error = GatewayError.notConnected
        let waiters = pending
        pending.removeAll()
        for (_, cont) in waiters { cont.resume(throwing: error) }

        let cWaiters = connectWaiters
        connectWaiters.removeAll()
        for w in cWaiters { w.resume(throwing: error) }
    }

    /// Send an RPC request and wait for the response.
    func request(method: String, params: [String: AnyCodable]? = nil, timeoutMs: Double? = nil) async throws -> Data {
        try await ensureConnected()
        let timeout = timeoutMs ?? defaultRequestTimeoutMs

        let id = UUID().uuidString
        let frame = RequestFrame(method: method, id: id, params: params.map { AnyCodable($0) })
        let data = try encoder.encode(frame)

        let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GatewayFrame, Error>) in
            pending[id] = cont

            // Timeout task
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000))
                await self?.timeoutRequest(id: id)
            }

            // Send task
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.wsTask?.send(.data(data))
                } catch {
                    let cont = await self.removePending(id: id)
                    await self.handleSendFailure(error)
                    cont?.resume(throwing: error)
                }
            }
        }

        guard case let .res(res) = response else {
            let err = GatewayError.responseError(method: method, code: "UNEXPECTED", message: "意外的帧类型")
            LogCollector.record(module: "网关连接", AppErrorText.localized(err.localizedDescription))
            throw err
        }

        if !res.ok {
            let code = res.error?["code"]?.value as? String ?? "GATEWAY_ERROR"
            let msg = res.error?["message"]?.value as? String ?? "网关错误"
            let err = GatewayError.responseError(method: method, code: code, message: msg)
            LogCollector.record(module: "网关连接", AppErrorText.localized(err.localizedDescription))
            throw err
        }

        if let payload = res.payload {
            return try encoder.encode(payload)
        }
        return Data()
    }

    /// Send a fire-and-forget message (no response expected).
    func send(method: String, params: [String: AnyCodable]? = nil) async throws {
        try await ensureConnected()
        let id = UUID().uuidString
        let frame = RequestFrame(method: method, id: id, params: params.map { AnyCodable($0) })
        let data = try encoder.encode(frame)

        do {
            try await wsTask?.send(.data(data))
        } catch {
            await handleSendFailure(error)
            throw error
        }
    }

    /// Decode a typed response from an RPC call.
    func requestDecoded<T: Decodable>(method: String, params: [String: AnyCodable]? = nil, timeoutMs: Double? = nil) async throws -> T {
        let data = try await request(method: method, params: params, timeoutMs: timeoutMs)
        return try decoder.decode(T.self, from: data)
    }

    /// Update connection URL and token (for settings changes).
    func updateConnection(url: URL, token: String?) {
        self.url = url
        self.token = token
    }

    var connectionState: ConnectionState {
        if isConnected { return .connected }
        if isConnecting { return .connecting }
        return .disconnected
    }

    // MARK: - Handshake

    private func performHandshake() async throws {
        // Step 1: Wait for connect.challenge
        let challenge = try await waitForChallenge()
        let nonce = challenge.nonce

        // Step 2: Build and send connect request
        let identity = DeviceIdentityManager.loadOrCreate()
        let gatewayHost = url.host ?? ""

        // 认证来源选择：镜像官方 GatewayChannel.selectConnectAuth。
        // - 显式 token（扫码/深链/手动输入的 token 字段）优先于已配对 deviceToken
        // - 显式 bootstrapToken（openclaw qr 配对码）强制走 bootstrap 配对路径，
        //   不复用旧 deviceToken（换网关/重新配对时不串号）
        // - 无显式凭据时复用已配对 deviceToken；仍无则兜底持久化配对码（历史 Onboarding 路径）
        let storedEntry = DeviceAuthTokenStore.loadToken(
            deviceId: identity.deviceId,
            role: role,
            gatewayHost: gatewayHost)
        let storedToken = storedEntry?.token
        let explicitToken = Self.trimmedNonEmpty(token)
        let explicitBootstrapToken = Self.trimmedNonEmpty(bootstrapToken)
        let explicitPassword = Self.trimmedNonEmpty(password)

        let authToken: String?
        if explicitToken != nil {
            authToken = explicitToken
        } else if explicitPassword == nil, explicitBootstrapToken == nil {
            authToken = storedToken
        } else {
            authToken = nil
        }

        let authBootstrapToken: String?
        if authToken == nil, explicitPassword == nil {
            if explicitBootstrapToken != nil {
                authBootstrapToken = explicitBootstrapToken
            } else if explicitToken == nil {
                authBootstrapToken = Self.trimmedNonEmpty(loadBootstrapTokenFromSettings())
            } else {
                authBootstrapToken = nil
            }
        } else {
            authBootstrapToken = nil
        }

        let authPassword = (authToken == nil && authBootstrapToken == nil) ? explicitPassword : nil
        let signingToken = authToken ?? authBootstrapToken

        // 镜像官方 resolveConnectScopes：用已配对 deviceToken 重连时以存档 scopes 为准，
        // 避免请求超出网关授予范围导致握手被拒（operator.admin 等网关未授予的 scope）。
        let usingStoredDeviceToken = explicitToken == nil && explicitBootstrapToken == nil
            && explicitPassword == nil && storedToken != nil
        let effectiveScopes: [String]
        if usingStoredDeviceToken, let storedScopes = storedEntry?.scopes, !storedScopes.isEmpty {
            effectiveScopes = storedScopes
        } else {
            effectiveScopes = scopes
        }

        // Prefer the gateway-issued challenge timestamp for device-auth signing
        // (matches official OpenClawKit). Local-clock fallback only for gateways
        // that omit ts; avoids clock-skew rejections ("配对码无效或已过期"/401).
        let signedAtMs = challenge.issuedAtMs.map { Int($0) } ?? Int(Date().timeIntervalSince1970 * 1000)
        let platform = "ios"
        let deviceFamily = await UIDevice.current.model.lowercased()

        // Use v2 payload format (compatible with all gateway versions).
        // v3 adds platform/deviceFamily but requires newer gateway builds.
        let authPayload = GatewayDeviceAuthPayload.buildV2(
            deviceId: identity.deviceId,
            clientId: "openclaw-ios",
            clientMode: clientMode,
            role: role,
            scopes: effectiveScopes,
            signedAtMs: signedAtMs,
            token: signingToken,
            nonce: nonce
        )

        logger.debug("handshake: v2 payload built, deviceId=\(identity.deviceId.prefix(8), privacy: .public)…")

        var params: [String: AnyCodable] = [
            "minProtocol": AnyCodable(gatewayMinimumProtocolVersion(role: role, clientMode: clientMode)),
            "maxProtocol": AnyCodable(GATEWAY_MAX_PROTOCOL_VERSION),
            "client": AnyCodable([
                "id": AnyCodable("openclaw-ios"),
                "displayName": AnyCodable(displayName),
                "version": AnyCodable(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"),
                "platform": AnyCodable(platform),
                "mode": AnyCodable(clientMode),
                "deviceFamily": AnyCodable(deviceFamily),
            ] as [String: AnyCodable]),
            "caps": AnyCodable(caps.map { AnyCodable($0) }),
            "commands": AnyCodable(commands.map { AnyCodable($0) }),
            "permissions": AnyCodable(permissions.mapValues { AnyCodable($0) }),
            "locale": AnyCodable(Locale.preferredLanguages.first ?? Locale.current.identifier),
            "userAgent": AnyCodable(ProcessInfo.processInfo.operatingSystemVersionString),
            "role": AnyCodable(role),
            "scopes": AnyCodable(effectiveScopes.map { AnyCodable($0) }),
        ]

        if let authBootstrapToken {
            params["auth"] = AnyCodable(["bootstrapToken": AnyCodable(authBootstrapToken)] as [String: AnyCodable])
        } else if let authToken {
            params["auth"] = AnyCodable(["token": AnyCodable(authToken)] as [String: AnyCodable])
        } else if let authPassword {
            params["auth"] = AnyCodable(["password": AnyCodable(authPassword)] as [String: AnyCodable])
        }

        if let device = GatewayDeviceAuthPayload.signedDeviceDictionary(
            payload: authPayload,
            identity: identity,
            signedAtMs: signedAtMs,
            nonce: nonce
        ) {
            params["device"] = AnyCodable(device)
        } else {
            logger.error("failed to build signed device dictionary")
        }

        let reqId = UUID().uuidString
        let frame = RequestFrame(method: "connect", id: reqId, params: AnyCodable(params))
        let data = try encoder.encode(frame)
        try await wsTask?.send(.data(data))

        // Step 3: Wait for connect response
        let response = try await waitForConnectResponse(reqId: reqId)
        try await handleConnectResponse(response, identity: identity)
    }

    private func waitForChallenge() async throws -> (nonce: String, issuedAtMs: Int64?) {
        try await withThrowingTaskGroup(of: (nonce: String, issuedAtMs: Int64?).self) { group in
            group.addTask { [weak self] in
                guard let self else { throw GatewayError.connectFailed("连接已释放") }
                while true {
                    guard let task = await self.wsTask else { throw GatewayError.connectFailed("没有可用连接") }
                    let msg = try await task.receive()
                    guard let data = self.decodeMessageData(msg),
                          let frame = try? self.decoder.decode(GatewayFrame.self, from: data),
                          case let .event(evt) = frame,
                          evt.event == "connect.challenge",
                          let payload = evt.payload?.dictValue,
                          let nonce = payload["nonce"]?.stringValue,
                          !nonce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    // Gateway-issued timestamp (ts) used as the signing timestamp so
                    // device-auth survives clock skew between phone and gateway.
                    let issuedAtMs: Int64?
                    if let ts = payload["ts"]?.intValue {
                        issuedAtMs = Int64(ts)
                    } else if let ts = payload["ts"]?.doubleValue {
                        issuedAtMs = Int64(ts)
                    } else {
                        issuedAtMs = nil
                    }
                    return (nonce, issuedAtMs)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.challengeTimeoutSeconds * 1_000_000_000))
                await self.cancelWebSocketTask()
                throw GatewayError.connectFailed("挑战超时")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func waitForConnectResponse(reqId: String) async throws -> ResponseFrame {
        guard let task = wsTask else {
            throw GatewayError.connectFailed("没有可用连接")
        }
        while true {
            let msg = try await task.receive()
            guard let data = decodeMessageData(msg),
                  let frame = try? decoder.decode(GatewayFrame.self, from: data),
                  case let .res(res) = frame,
                  res.id == reqId
            else { continue }
            return res
        }
    }

    private func handleConnectResponse(_ res: ResponseFrame, identity: DeviceIdentity) async throws {
        guard res.ok else {
            if let error = classifyConnectError(res.error) {
                throw error
            }
            let msg = res.error?["message"]?.value as? String ?? "网关连接被拒绝"
            throw GatewayError.connectFailed(msg)
        }

        guard let payload = res.payload else {
            throw GatewayError.connectFailed("缺少响应数据")
        }

        let payloadData = try encoder.encode(payload)
        let ok = try decoder.decode(HelloOk.self, from: payloadData)

        // Record server-advertised methods for approval dual-protocol detection.
        serverMethods = ok.advertisedServerMethods()

        // Extract tick interval
        if let tick = ok.policy["tickIntervalMs"]?.value as? Double {
            tickIntervalMs = tick
        } else if let tick = ok.policy["tickIntervalMs"]?.value as? Int {
            tickIntervalMs = Double(tick)
        }

        // Store device token if returned
        let gatewayHost = url.host ?? ""
        var bestNodeToken: String?
        if let auth = ok.auth,
           let deviceToken = auth["deviceToken"]?.stringValue {
            let authRole = auth["role"]?.stringValue ?? role
            let scopeValues = auth["scopes"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            DeviceAuthTokenStore.storeToken(
                deviceId: identity.deviceId,
                role: authRole,
                gatewayHost: gatewayHost,
                token: deviceToken,
                scopes: scopeValues
            )
            if authRole == "node" { bestNodeToken = deviceToken }
            // 同步把配对下发的 device token 传给 App 层（写入 settings.gatewayToken），
            // 供 HTTP 工具调用 / 诊断鉴权等使用（配对场景 settings.gatewayToken 原本为空）。
            deviceTokenHandler?(deviceToken)
        }

        // 官方多角色 handoff：bootstrap 配对成功后网关会下发 deviceTokens 数组
        // （node / operator 各自独立令牌）。仅存单 deviceToken 会导致另一角色重连无凭据，
        // 表现为扫码配对成功后网关/节点会话仍连不上。
        if let auth = ok.auth,
           let tokenEntries = auth["deviceTokens"]?.arrayValue {
            for entry in tokenEntries {
                guard let dict = entry.dictValue,
                      let deviceToken = dict["deviceToken"]?.stringValue,
                      let authRole = dict["role"]?.stringValue
                else { continue }
                let scopeValues = dict["scopes"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                DeviceAuthTokenStore.storeToken(
                    deviceId: identity.deviceId,
                    role: authRole,
                    gatewayHost: gatewayHost,
                    token: deviceToken,
                    scopes: scopeValues
                )
                if authRole == "node", bestNodeToken == nil {
                    bestNodeToken = deviceToken
                }
            }
        }
        // 若单 deviceToken 未覆盖 node 令牌（例如本连接是 operator 角色），
        // 把 node 令牌同步给 App 层作网关令牌，供 HTTP 工具/诊断鉴权使用。
        if let bestNodeToken {
            deviceTokenHandler?(bestNodeToken)
        }

        lastTick = Date()
        startTickWatcher()
        await pushHandler?(.snapshot(ok))

        logger.info("gateway connected (protocol \(ok._protocol))")
    }

    // MARK: - Message Loop

    private func listen() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Task { await self.handleReceiveFailure(err) }
            case .success(let msg):
                Task {
                    await self.handleMessage(msg)
                    await self.listen()
                }
            }
        }
    }

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message) async {
        guard let data = decodeMessageData(msg),
              let frame = try? decoder.decode(GatewayFrame.self, from: data)
        else {
            LogCollector.record(module: "网关连接", "网关消息解析失败：无法解码收到的帧")
            return
        }

        switch frame {
        case .res(let res):
            if let cont = pending.removeValue(forKey: res.id) {
                cont.resume(returning: .res(res))
            }
        case .event(let evt):
            if evt.event == "connect.challenge" { return }
            if let seq = evt.seq {
                if let last = lastSeq, seq > last + 1 {
                    await pushHandler?(.seqGap(expected: last + 1, received: seq))
                }
                lastSeq = seq
            }
            if evt.event == "tick" { lastTick = Date() }
            await pushHandler?(.event(evt))
        default:
            break
        }
    }

    private func handleReceiveFailure(_ err: Error) async {
        logger.error("gateway receive failed: \(err.localizedDescription, privacy: .public)")
        LogCollector.record(module: "网关连接", "网关连接中断：\(AppErrorText.localized(err.localizedDescription))")
        isConnected = false
        keepaliveTask?.cancel(); keepaliveTask = nil
        await stateHandler?(.disconnected)
        failAllPending(err)
        await scheduleReconnect()
    }

    private nonisolated func decodeMessageData(_ msg: URLSessionWebSocketTask.Message) -> Data? {
        switch msg {
        case .data(let d): return d
        case .string(let s): return s.data(using: .utf8)
        @unknown default: return nil
        }
    }

    // MARK: - Keepalive & Tick Watcher

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            guard let self else { return }
            while await self.shouldReconnect {
                guard await self.sleepUnlessCancelled(seconds: self.keepaliveIntervalSeconds) else { return }
                guard await self.isConnected, let task = await self.wsTask else { continue }
                try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    task.sendPing { error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume(returning: ()) }
                    }
                }
            }
        }
    }

    private func startTickWatcher() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self else { return }
            let tolerance = await self.tickIntervalMs * 2
            while await self.isConnected {
                guard await self.sleepUnlessCancelled(seconds: tolerance / 1000) else { return }
                guard await self.isConnected else { return }
                if let last = await self.lastTick {
                    let delta = Date().timeIntervalSince(last) * 1000
                    if delta > tolerance {
                        self.logger.error("gateway tick missed; reconnecting")
                        LogCollector.record(module: "网关连接", "网关心跳超时（tick 丢失），正在重连")
                        await self.markDisconnected()
                        await self.scheduleReconnect()
                        return
                    }
                }
            }
        }
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            guard let self else { return }
            while await self.shouldReconnect {
                guard await self.sleepUnlessCancelled(seconds: 30) else { return }
                guard await self.shouldReconnect else { return }
                if await self.isConnected { continue }
                do {
                    try await self.connect()
                } catch {
                    self.logger.error("watchdog reconnect failed: \(error.localizedDescription, privacy: .public)")
                    LogCollector.record(module: "网关连接", "网关看门狗重连失败：\(AppErrorText.localized(error.localizedDescription))")
                }
            }
        }
    }

    // MARK: - Reconnection

    private func scheduleReconnect() async {
        guard shouldReconnect else { return }
        let delay = backoffMs / 1000
        backoffMs = min(backoffMs * 2, 30000)
        guard await sleepUnlessCancelled(seconds: delay) else { return }
        guard shouldReconnect else { return }
        do {
            try await connect()
        } catch {
            logger.error("reconnect failed: \(error.localizedDescription, privacy: .public)")
            LogCollector.record(module: "网关连接", "网关自动重连失败：\(AppErrorText.localized(error.localizedDescription))")
            await scheduleReconnect()
        }
    }

    private func markDisconnected() {
        isConnected = false
        keepaliveTask?.cancel(); keepaliveTask = nil
        failAllPending(GatewayError.notConnected)
        Task { await stateHandler?(.disconnected) }
    }

    // MARK: - Helpers

    /// 把 connect 响应错误归类为可识别的配对错误。
    /// - not-paired：远程设备配对需要网关管理端审批。
    /// - bootstrap_token_invalid：配对码无效/过期/已被其他设备绑定。
    private func classifyConnectError(_ error: [String: AnyCodable]?) -> GatewayError? {
        guard let error else { return nil }

        let details = error["details"]?.dictValue ?? [:]
        let detailCode = details["code"]?.stringValue ?? ""
        let topCode = error["code"]?.stringValue ?? ""
        let reason = details["reason"]?.stringValue ?? ""
        let authReason = details["authReason"]?.stringValue ?? error["authReason"]?.stringValue ?? ""

        if detailCode == "PAIRING_REQUIRED" || topCode.lowercased() == "not-paired" || reason == "not-paired" {
            return .pairingRequired(requestId: details["requestId"]?.stringValue)
        }
        if detailCode == "AUTH_BOOTSTRAP_TOKEN_INVALID" || authReason == "bootstrap_token_invalid" {
            return .bootstrapTokenInvalid
        }
        // ???? GatewayErrors??? AUTH_*/DEVICE_AUTH_* ??? ? ??????
        let code = detailCode.isEmpty ? topCode : detailCode
        switch code {
        case "AUTH_TOKEN_MISMATCH", "AUTH_TOKEN_MISSING", "AUTH_TOKEN_NOT_CONFIGURED",
             "AUTH_UNAUTHORIZED", "UNAUTHORIZED", "AUTH_REQUIRED":
            return .connectFailed("???????????????????????????")
        case "AUTH_DEVICE_TOKEN_MISMATCH", "DEVICE_AUTH_INVALID", "DEVICE_IDENTITY_REQUIRED":
            return .connectFailed("??????????????")
        case "AUTH_SIGNATURE_INVALID", "DEVICE_AUTH_SIGNATURE_INVALID",
             "DEVICE_AUTH_NONCE_MISMATCH", "DEVICE_AUTH_NONCE_REQUIRED",
             "DEVICE_AUTH_DEVICE_ID_MISMATCH", "DEVICE_AUTH_PUBLIC_KEY_INVALID":
            return .connectFailed("?????????????????????????")
        case "AUTH_SIGNATURE_EXPIRED", "DEVICE_AUTH_SIGNATURE_EXPIRED":
            return .connectFailed("??????????????????")
        case "AUTH_SCOPE_MISMATCH", "MISSING_SCOPE":
            return .connectFailed("?????????????????")
        case "AUTH_PASSWORD_MISMATCH", "AUTH_PASSWORD_MISSING", "AUTH_PASSWORD_NOT_CONFIGURED":
            return .connectFailed("????????????????")
        case "AUTH_RATE_LIMITED":
            return .connectFailed("??????????????????")
        case "AUTH_TAILSCALE_IDENTITY_MISMATCH", "AUTH_TAILSCALE_IDENTITY_MISSING",
             "AUTH_TAILSCALE_PROXY_MISSING", "AUTH_TAILSCALE_WHOIS_FAILED":
            return .connectFailed("Tailscale ???????????? Tailscale ??")
        default:
            break
        }
        return nil
    }

    /// 去除首尾空白；空串返回 nil。
    private nonisolated static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 读取持久化的配对令牌：优先钥匙串（SecureStorage.bootstrapTokenKey），旧存档兜底 UserDefaults。
    /// Onboarding 扫码/粘贴配对码后由 SettingsStore.save() 写入钥匙串。
    private func loadBootstrapTokenFromSettings() -> String? {
        if let token = SecureStorage.shared.getString(SecureStorage.bootstrapTokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        // 兜底：升级前的旧存档仍从 UserDefaults 读取（SettingsStore.init 会迁移到钥匙串）
        guard let data = UserDefaults.standard.data(forKey: "app_settings"),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data),
              let token = settings.bootstrapToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Cancel the current WebSocket task. Used by timeout handlers to unblock pending receive() calls.
    private func cancelWebSocketTask() {
        wsTask?.cancel(with: .goingAway, reason: nil)
    }

    private func ensureConnected() async throws {
        try await connect()
    }

    private func removePending(id: String) -> CheckedContinuation<GatewayFrame, Error>? {
        pending.removeValue(forKey: id)
    }

    private func handleSendFailure(_ error: Error) async {
        isConnected = false
        wsTask?.cancel(with: .goingAway, reason: nil)
        await stateHandler?(.disconnected)
        await scheduleReconnect()
    }

    private func failAllPending(_ error: Error) {
        let waiters = pending
        pending.removeAll()
        for (_, cont) in waiters {
            cont.resume(throwing: error)
        }
    }

    private func timeoutRequest(id: String) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: GatewayError.requestTimeout(id))
    }

    private nonisolated func sleepUnlessCancelled(seconds: Double) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}
