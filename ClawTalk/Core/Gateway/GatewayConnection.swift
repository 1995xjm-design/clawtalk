import Foundation
import OSLog
import UIKit
import UserNotifications

/// High-level gateway connection wrapper over GatewayWebSocket.
/// Provides chat-specific methods and event routing.
@Observable
@MainActor
final class GatewayConnection {

    enum State: Sendable {
        case disconnected
        case connecting
        case connected
    }

    // MARK: - Observable State

    private(set) var connectionState: State = .disconnected
    private(set) var lastError: String?
    private(set) var pendingApprovals: [PendingApproval] = []
    /// ??????????? question ???operator.questions ????
    private(set) var pendingQuestions: [QuestionRecord] = []
    private(set) var agentStatus: AgentStatusInfo?
    /// 审批到达但系统通知未授权时的引导提示（对齐官方 NotificationPermissionGuidanceDialog）。
    private(set) var pendingNotificationGuidance: NotificationGuidancePrompt?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openclaw.clawtalk", category: "gateway-conn")
    private var gateway: GatewayWebSocket?
    private var eventContinuations: [UUID: AsyncStream<ChatEventPayload>.Continuation] = [:]

    // MARK: - Connection Lifecycle

    /// Connect to the gateway WebSocket.
    /// - Parameter resolvedURL: Full WebSocket URL (e.g. wss://host/ws or ws://host:18789).
    func connect(resolvedURL: String, token: String) async {
        guard let wsURL = URL(string: resolvedURL) else {
            lastError = "无效的 WebSocket URL：\(resolvedURL)"
            LogCollector.record(module: "网关连接", lastError ?? "")
            return
        }

        // Shut down existing connection if any
        if let existing = gateway {
            await existing.shutdown()
        }

        connectionState = .connecting
        lastError = nil
        logger.info("gateway connecting to \(wsURL.absoluteString, privacy: .public)")

        // TLS first-trust gate (TOFU): prompt before trusting an untrusted wss host.
        if wsURL.scheme?.lowercased() == "wss",
           let host = wsURL.host,
           !(await TLSFingerprintGate.shared.ensureTrust(host: host, port: wsURL.port ?? 443))
        {
            connectionState = .disconnected
            lastError = "未信任网关证书，已取消连接"
            LogCollector.record(module: "网关连接", lastError ?? "")
            return
        }

        // 配对成功后 node/operator 各持独立 deviceToken：按角色优先用已配对令牌，
        // 避免把 node 令牌错当 operator 令牌用导致另一角色重连被网关拒绝。
        let resolvedToken = await Self.resolveStoredDeviceToken(
            role: "operator",
            host: wsURL.host,
            fallback: token)
        let gw = GatewayWebSocket(
            url: wsURL,
            token: resolvedToken,
            pushHandler: { [weak self] push in
                await self?.handlePush(push)
            },
            stateHandler: { [weak self] state in
                await self?.handleStateChange(state)
            }
        )
        gateway = gw

        do {
            try await gw.connect()
            logger.info("gateway connect succeeded, setting state to .connected")
            connectionState = .connected
            Task { [weak self] in await self?.refreshQuestions() }
        } catch {
            logger.error("gateway connect failed: \(error.localizedDescription, privacy: .public)")
            connectionState = .disconnected
            lastError = error.localizedDescription
            LogCollector.record(module: "网关连接", AppErrorText.localized(error.localizedDescription))
        }
    }

    /// 按角色解析已配对 deviceToken：有则用它，没有则回退 App 级网关令牌（手动共享令牌场景）。
    private static func resolveStoredDeviceToken(role: String, host: String?, fallback: String) async -> String? {
        guard let host else { return fallback.isEmpty ? nil : fallback }
        let deviceId = DeviceIdentityManager.loadOrCreate().deviceId
        if let stored = DeviceAuthTokenStore.loadToken(deviceId: deviceId, role: role, gatewayHost: host)?.token,
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return fallback.isEmpty ? nil : fallback
    }

    /// Disconnect from the gateway.
    func disconnect() async {
        if let gw = gateway {
            await gw.shutdown()
        }
        gateway = nil
        connectionState = .disconnected
    }

    // MARK: - Chat

    /// Send a chat message via WebSocket. Returns the runId for tracking events.
    /// - Parameter images: Optional array of JPEG image data sent as base64 attachments.
    func chatSend(
        sessionKey: String,
        message: String,
        images: [Data]? = nil,
        idempotencyKey: String = UUID().uuidString,
        timeoutMs: Int = 30000
    ) async throws -> ChatSendResponse {
        guard let gw = gateway else { throw GatewayWebSocket.GatewayError.notConnected }

        var params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(sessionKey),
            "message": AnyCodable(message),
            "thinking": AnyCodable(""),
            "idempotencyKey": AnyCodable(idempotencyKey),
            "timeoutMs": AnyCodable(timeoutMs),
        ]

        if let images, !images.isEmpty {
            let attachments: [[String: AnyCodable]] = images.map { data in
                [
                    "type": AnyCodable("image"),
                    "mimeType": AnyCodable("image/jpeg"),
                    "content": AnyCodable(data.base64EncodedString()),
                ]
            }
            params["attachments"] = AnyCodable(attachments.map { AnyCodable($0) })
        }

        return try await gw.requestDecoded(
            method: "chat.send",
            params: params,
            timeoutMs: Double(timeoutMs)
        )
    }

    /// Fetch chat history from the server.
    func chatHistory(sessionKey: String, limit: Int? = nil) async throws -> ChatHistoryPayload {
        guard let gw = gateway else { throw GatewayWebSocket.GatewayError.notConnected }

        var params: [String: AnyCodable] = ["sessionKey": AnyCodable(sessionKey)]
        if let limit { params["limit"] = AnyCodable(limit) }

        return try await gw.requestDecoded(method: "chat.history", params: params)
    }

    /// Abort an in-progress chat run.
    func chatAbort(sessionKey: String, runId: String) async throws -> Bool {
        guard let gw = gateway else { throw GatewayWebSocket.GatewayError.notConnected }

        struct AbortResponse: Decodable { let ok: Bool?; let aborted: Bool? }
        let res: AbortResponse = try await gw.requestDecoded(
            method: "chat.abort",
            params: [
                "sessionKey": AnyCodable(sessionKey),
                "runId": AnyCodable(runId),
            ]
        )
        return res.aborted ?? false
    }

    /// Subscribe to chat events. Returns an AsyncStream that yields ChatEventPayload.
    /// Call this BEFORE chatSend to ensure no events are missed.
    func subscribeChatEvents() -> (id: UUID, stream: AsyncStream<ChatEventPayload>) {
        let id = UUID()
        let stream = AsyncStream<ChatEventPayload> { continuation in
            self.eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
        return (id, stream)
    }

    /// Unsubscribe from chat events.
    func unsubscribeChatEvents(id: UUID) {
        eventContinuations[id]?.finish()
        eventContinuations.removeValue(forKey: id)
    }

    // MARK: - Models

    /// Fetch available models via WebSocket RPC.
    func modelsList() async throws -> [ModelEntry] {
        guard let gw = gateway else { throw GatewayWebSocket.GatewayError.notConnected }
        let response: ModelsListResponse = try await gw.requestDecoded(method: "models.list")
        return response.models
    }

    // MARK: - Exec Approvals

    /// 官方 approval 双协议：unified（approval.get/approval.resolve）与 legacy（exec.approval.*）。
    private enum ApprovalRPCFamily {
        case unified
        case legacy
        case unavailable
    }

    private func execApprovalFamily(gw: GatewayWebSocket) async -> ApprovalRPCFamily {
        let unifiedGet = await gw.supportsServerMethod("approval.get")
        let unifiedResolve = await gw.supportsServerMethod("approval.resolve")
        let legacyGet = await gw.supportsServerMethod("exec.approval.get")
        let legacyResolve = await gw.supportsServerMethod("exec.approval.resolve")
        if unifiedGet == true, unifiedResolve == true { return .unified }
        if unifiedGet == false, unifiedResolve == false,
           legacyGet == true, legacyResolve == true { return .legacy }
        return .unavailable
    }

    /// Resolve a pending exec approval. 自动按网关广播方法选择 unified/legacy 协议族
    /// （官方 execApprovalRPCFamily：supportsServerMethod 探测，二选一）。
    func resolveApproval(id: String, decision: String) async throws {
        guard let gw = gateway else { throw GatewayWebSocket.GatewayError.notConnected }
        switch await execApprovalFamily(gw: gw) {
        case .unified:
            let _: UnifiedApprovalResolveResult = try await gw.requestDecoded(
                method: "approval.resolve",
                params: [
                    "id": AnyCodable(id),
                    "kind": AnyCodable("exec"),
                    "decision": AnyCodable(decision),
                ]
            )
        case .legacy, .unavailable:
            let _: ApprovalResolveResponse = try await gw.requestDecoded(
                method: "exec.approval.resolve",
                params: [
                    "id": AnyCodable(id),
                    "decision": AnyCodable(decision),
                ]
            )
        }
        // Remove from pending list immediately
        pendingApprovals.removeAll { $0.id == id }
        logger.info("approval resolved: \(id, privacy: .public) → \(decision, privacy: .public)")
    }

    /// 拉取审批的规范快照（unified approval.get / legacy exec.approval.get 按协议族选择），
    /// 对齐官方通知链路的 canonical readback。
    func fetchApproval(id: String) async throws -> PendingApproval? {
        guard let gw = gateway else { throw GatewayWebSocket.GatewayError.notConnected }
        switch await execApprovalFamily(gw: gw) {
        case .unified:
            let result: UnifiedApprovalFetchEnvelope = try await gw.requestDecoded(
                method: "approval.get",
                params: ["id": AnyCodable(id)])
            return Self.makePendingApproval(from: result.approval)
        case .legacy:
            let result: LegacyApprovalFetchResult = try await gw.requestDecoded(
                method: "exec.approval.get",
                params: ["id": AnyCodable(id)])
            return Self.makePendingApproval(from: result)
        case .unavailable:
            return nil
        }
    }

    // MARK: - Push Relay Identity (gateway.identity.get)

    /// 网关中继身份（Push Relay）：deviceId + publicKey，官方 GatewayRelayIdentityResponse。
    func fetchPushRelayGatewayIdentity() async throws -> PushRelayGatewayIdentity {
        guard let gw = gateway else { throw GatewayWebSocket.GatewayError.notConnected }
        let response: GatewayRelayIdentityResponse = try await gw.requestDecoded(
            method: "gateway.identity.get")
        return PushRelayGatewayIdentity(
            deviceId: response.deviceId,
            publicKey: response.publicKey
        )
    }

    // MARK: - Pairing (device.pair.setupCode)

    /// 生成手机端配对码（官方 sendDirectWatchSetup：params {"includeQr":false,"bootstrapProfile":"node"}）。
    func generateNodeSetupCode() async throws -> String {
        guard let gw = gateway else { throw GatewayWebSocket.GatewayError.notConnected }
        struct SetupCodeResponse: Decodable { let setupCode: String }
        let response: SetupCodeResponse = try await gw.requestDecoded(
            method: "device.pair.setupCode",
            params: [
                "includeQr": AnyCodable(false),
                "bootstrapProfile": AnyCodable("node"),
            ]
        )
        return response.setupCode
    }

    /// Remove expired approvals.
    func pruneExpiredApprovals() {
        pendingApprovals.removeAll { $0.isExpired }
    }

    // MARK: - RPC Convenience

    /// Make a raw RPC request.
    func request(method: String, params: [String: AnyCodable]? = nil, timeoutMs: Double? = nil) async throws -> Data {
        guard let gw = gateway else { throw GatewayWebSocket.GatewayError.notConnected }
        return try await gw.request(method: method, params: params, timeoutMs: timeoutMs)
    }

    /// Whether the gateway advertised support for the given RPC method (nil = 未收到 snapshot).
    func supportsServerMethod(_ method: String) -> Bool? {
        gateway?.supportsServerMethod(method)
    }

    // MARK: - Event Handling

    private func handlePush(_ push: GatewayWebSocket.Push) async {
        switch push {
        case .snapshot(let hello):
            logger.info("gateway snapshot received (uptime: \(hello.snapshot.uptimems)ms)")
        case .event(let evt):
            switch evt.event {
            case "chat":
                decodeChatEvent(evt)
            case "exec.approval.requested":
                await handleApprovalRequested(evt)
            case "exec.approval.resolved":
                handleApprovalResolved(evt)
            case "agent":
                handleAgentEvent(evt)
            case "question.requested":
                handleQuestionRequested(evt)
            case "question.resolved":
                handleQuestionResolved(evt)
            default:
                break
            }
        case .seqGap(let expected, let received):
            logger.warning("event sequence gap: expected \(expected), got \(received)")
        }
    }

    private func decodeChatEvent(_ evt: EventFrame) {
        guard let payload = evt.payload else { return }

        // Encode AnyCodable back to JSON, then decode to typed struct
        guard let data = try? JSONEncoder().encode(payload),
              let chatEvent = try? JSONDecoder().decode(ChatEventPayload.self, from: data)
        else { return }

        for (_, continuation) in eventContinuations {
            continuation.yield(chatEvent)
        }
    }

    private func handleApprovalRequested(_ evt: EventFrame) async {
        guard let payload = evt.payload,
              let data = try? JSONEncoder().encode(payload),
              let event = try? JSONDecoder().decode(ExecApprovalEvent.self, from: data)
        else {
            logger.error("failed to decode exec.approval.requested")
            return
        }

        let approval = PendingApproval(
            id: event.id,
            command: event.request.command,
            commandArgv: event.request.commandArgv,
            cwd: event.request.cwd,
            host: event.request.host,
            agentId: event.request.agentId,
            ask: event.request.ask,
            warningText: event.request.warningText,
            createdAt: Date(timeIntervalSince1970: event.createdAtMs / 1000),
            expiresAt: Date(timeIntervalSince1970: event.expiresAtMs / 1000)
        )

        // Don't add duplicates
        if !pendingApprovals.contains(where: { $0.id == approval.id }) {
            pendingApprovals.append(approval)
            Haptics.warning()
            logger.info("approval requested: \(approval.displayCommand, privacy: .public)")

            // 审批到达且通知未开启 → 弹出引导（对齐官方：可持久化不再显示）
            await presentNotificationGuidanceIfNeeded()
        }
    }

    /// 审批到达但系统通知未授权时，弹出「通知未开启」引导。
    private func presentNotificationGuidanceIfNeeded() async {
        guard pendingNotificationGuidance == nil,
              !ExecApprovalNotificationGuidance.isSuppressed else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard !ExecApprovalNotificationGuidance.isNotificationAuthorizationAllowed(settings.authorizationStatus) else { return }
        pendingNotificationGuidance = NotificationGuidancePrompt()
    }

    /// 关闭通知引导；suppressFuture 为 true 时持久化「不再显示」。
    func dismissNotificationGuidance(suppressFuture: Bool) {
        if suppressFuture {
            ExecApprovalNotificationGuidance.suppressFuture()
        }
        pendingNotificationGuidance = nil
    }

    private func handleApprovalResolved(_ evt: EventFrame) {
        guard let payload = evt.payload,
              let data = try? JSONEncoder().encode(payload),
              let event = try? JSONDecoder().decode(ExecApprovalResolvedEvent.self, from: data)
        else { return }

        pendingApprovals.removeAll { $0.id == event.id }
        logger.info("approval resolved externally: \(event.id, privacy: .public) → \(event.decision, privacy: .public)")
    }

    private func handleAgentEvent(_ evt: EventFrame) {
        guard let payload = evt.payload,
              let data = try? JSONEncoder().encode(payload),
              let status = try? JSONDecoder().decode(AgentStatusInfo.self, from: data)
        else { return }

        agentStatus = status
        logger.info("agent status: \(status.status ?? "unknown", privacy: .public)")
    }

    // MARK: - Question Protocol??? question.requested/resolved + question.list/get/resolve?

    private func handleQuestionRequested(_ evt: EventFrame) {
        guard let payload = evt.payload,
              let data = try? JSONEncoder().encode(payload),
              let record = try? JSONDecoder().decode(QuestionRecord.self, from: data)
        else {
            logger.error("failed to decode question.requested")
            return
        }
        if !pendingQuestions.contains(where: { $0.id == record.id }) {
            pendingQuestions.append(record)
            logger.info("question requested: \(record.id, privacy: .public) x\(record.questions.count)")
            Haptics.warning()
        }
    }

    private func handleQuestionResolved(_ evt: EventFrame) {
        guard let payload = evt.payload,
              let data = try? JSONEncoder().encode(payload),
              let event = try? JSONDecoder().decode(OpenClawQuestionResolvedEvent.self, from: data)
        else { return }

        if let idx = pendingQuestions.firstIndex(where: { $0.id == event.id }) {
            let record = pendingQuestions[idx]
            pendingQuestions.remove(at: idx)
            logger.info("question resolved: \(event.id, privacy: .public) -> \(event.status.rawValue, privacy: .public)")
            _ = record
        }
    }

    /// question.list????????????????????????
    func refreshQuestions() async {
        guard let gw = gateway else { return }
        do {
            let data = try await gw.request(method: "question.list", params: nil)
            let result = try JSONDecoder().decode(QuestionListResult.self, from: data)
            let listed = result.questions
            var seen = Set<String>()
            for record in listed {
                seen.insert(record.id)
                if record.isPending,
                   !pendingQuestions.contains(where: { $0.id == record.id })
                {
                    pendingQuestions.append(record)
                }
            }
            // ????????????????/??/?????????
            pendingQuestions.removeAll { !$0.isPending }
        } catch {
            // ???? question.list ????official ???? INVALID_REQUEST: unknown method?
            logger.info("question.list unavailable: \(error.localizedDescription)")
        }
    }

    /// question.get?? id ?????????
    func getQuestion(id: String) async throws -> QuestionRecord {
        let data = try await request(method: "question.get", params: ["id": AnyCodable(id)])
        return try JSONDecoder().decode(QuestionGetResult.self, from: data).question
    }

    /// question.resolve??????questionId -> ????? label / ???????
    func resolveQuestion(id: String, answers: [String: [String]]) async throws {
        _ = try await request(method: "question.resolve", params: [
            "id": AnyCodable(id),
            "answers": AnyCodable(answers),
        ])
    }

    /// question.resolve + cancel???/??????
    func cancelQuestion(id: String) async throws {
        _ = try await request(method: "question.resolve", params: [
            "id": AnyCodable(id),
            "cancel": AnyCodable(true),
        ])
    }

    /// ????????UI ??????
    func pruneExpiredQuestions() {
        pendingQuestions.removeAll { !$0.isPending || $0.expiresAt < Date() }
    }

    private func handleStateChange(_ state: GatewayWebSocket.ConnectionState) {
        let newState: State = switch state {
        case .connected: .connected
        case .connecting: .connecting
        case .disconnected: .disconnected
        }
        logger.info("gateway state: \(String(describing: self.connectionState)) → \(String(describing: newState))")
        connectionState = newState

        if newState == .disconnected {
            pendingApprovals.removeAll()
            pendingQuestions.removeAll()
            agentStatus = nil
        }
    }

}

// MARK: - Chat Event Types

struct ChatSendResponse: Codable, Sendable {
    let runId: String
    let status: String
}

struct ChatEventPayload: Codable, Sendable {
    let runId: String?
    let sessionKey: String?
    let state: String?     // "delta", "final", "error"
    let message: ChatEventMessage?
    let errorMessage: String?
    let stopReason: String?
}

struct ChatEventMessage: Codable, Sendable {
    let role: String?
    let content: [ChatEventContent]?
    let timestamp: Int?
}

struct ChatEventContent: Codable, Sendable {
    let type: String?
    let text: String?
}

struct ChatHistoryPayload: Codable, Sendable {
    let sessionKey: String?
    let sessionId: String?
    let messages: [ChatHistoryMessage]?
    let thinkingLevel: String?
}

struct ChatHistoryMessage: Codable, Sendable {
    let role: String?
    let content: AnyCodable?  // Can be string or array of content parts
    let timestamp: Int?
}

// MARK: - Approval Response

struct ApprovalResolveResponse: Decodable {
    let ok: Bool?
}

// MARK: - Agent Status

struct AgentStatusInfo: Decodable, Sendable {
    let status: String?
    let agentId: String?
    let sessionKey: String?
    let message: String?
}


// MARK: - Approval Dual-Protocol Types (official parity)

/// unified approval.resolve 响应（applied + 终态 approval 快照）。
struct UnifiedApprovalResolveResult: Decodable, Sendable {
    let applied: Bool?
    let approval: [String: AnyCodable]?
}

/// unified approval.get 响应信封。
struct UnifiedApprovalFetchEnvelope: Decodable, Sendable {
    let approval: UnifiedApprovalSnapshot
}

struct UnifiedApprovalSnapshot: Decodable, Sendable {
    let id: String
    let status: String?
    let createdAtMs: Int?
    let expiresAtMs: Int?
    let presentation: [String: AnyCodable]?

    private enum CodingKeys: String, CodingKey {
        case id, status, presentation
        case createdAtMs = "createdAtMs"
        case expiresAtMs = "expiresAtMs"
    }
}

/// legacy exec.approval.get 响应。
struct LegacyApprovalFetchResult: Decodable, Sendable {
    let id: String
    let commandText: String
    let commandPreview: String?
    let warningText: String?
    let host: String?
    let nodeId: String?
    let agentId: String?
    let createdAtMs: Int64?
    let expiresAtMs: Int64?

    private enum CodingKeys: String, CodingKey {
        case id, host
        case commandText = "commandText"
        case commandPreview = "commandPreview"
        case warningText = "warningText"
        case nodeId = "nodeId"
        case agentId = "agentId"
        case createdAtMs = "createdAtMs"
        case expiresAtMs = "expiresAtMs"
    }
}

// MARK: - Push Relay Identity Types (official parity)

struct GatewayRelayIdentityResponse: Decodable, Sendable {
    let deviceId: String
    let publicKey: String
}

struct PushRelayGatewayIdentity: Sendable, Equatable {
    let deviceId: String
    let publicKey: String
}

extension GatewayConnection {
    fileprivate static func makePendingApproval(from legacy: LegacyApprovalFetchResult) -> PendingApproval {
        let created = legacy.createdAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        let expires = legacy.expiresAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            ?? created.addingTimeInterval(3600)
        return PendingApproval(
            id: legacy.id,
            command: legacy.commandText,
            commandArgv: nil,
            cwd: nil,
            host: legacy.host,
            agentId: legacy.agentId,
            ask: legacy.commandPreview,
            warningText: legacy.warningText,
            createdAt: created,
            expiresAt: expires
        )
    }

    fileprivate static func makePendingApproval(from unified: UnifiedApprovalSnapshot) -> PendingApproval? {
        let presentation = unified.presentation
        let created = unified.createdAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        let expires = unified.expiresAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            ?? created.addingTimeInterval(3600)
        return PendingApproval(
            id: unified.id,
            command: presentation?["commandText"]?.stringValue ?? "命令",
            commandArgv: nil,
            cwd: nil,
            host: presentation?["host"]?.stringValue,
            agentId: presentation?["agentId"]?.stringValue,
            ask: presentation?["commandPreview"]?.stringValue,
            warningText: presentation?["warningText"]?.stringValue,
            createdAt: created,
            expiresAt: expires
        )
    }
}
