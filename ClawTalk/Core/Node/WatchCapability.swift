import Foundation
import WatchConnectivity

/// Watch capability mirroring official OpenClawWatchCommand (watch.status / watch.notify).
/// Reuses the existing WCSession channel (ClawTalkWatchSessionCoordinator owns the delegate).
enum WatchCapability {

    struct StatusPayload: Encodable {
        let supported: Bool
        let paired: Bool
        let appInstalled: Bool
        let reachable: Bool
        let activationState: String
    }

    struct NotifyParams: Decodable {
        let title: String
        let body: String
        let priority: String?
        let promptId: String?
        let sessionKey: String?
        let gatewayStableID: String?
        let kind: String?
        let details: String?
        let expiresAtMs: Int64?
        let risk: String?
        let actions: [WatchAction]?
    }

    struct WatchAction: Decodable {
        let id: String
        let label: String
        let style: String?
    }

    struct NotifyResult: Encodable {
        let deliveredImmediately: Bool
        let queuedForDelivery: Bool
        let transport: String
    }

    enum WatchError: LocalizedError {
        case unsupported
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "WatchConnectivity unsupported"
            case .failed(let msg): return msg
            }
        }
    }

    static func status() -> StatusPayload {
        let supported = WCSession.isSupported()
        let session = WCSession.default
        let state: String
        switch session.activationState {
        case .activated: state = "activated"
        case .inactive: state = "inactive"
        case .notActivated: state = "notActivated"
        @unknown default: state = "unknown"
        }
        return StatusPayload(
            supported: supported,
            paired: session.isPaired,
            appInstalled: session.isWatchAppInstalled,
            reachable: session.isReachable,
            activationState: state
        )
    }

    /// watch.notify: push a notification to the paired watch over WCSession.
    static func notify(params: NotifyParams) throws -> NotifyResult {
        guard WCSession.isSupported() else { throw WatchError.unsupported }
        let session = WCSession.default
        if session.activationState != .activated {
            session.activate()
        }

        var payload: [String: Any] = [
            "kind": "notify",
            "title": params.title,
            "body": params.body,
        ]
        if let priority = params.priority { payload["priority"] = priority }
        if let promptId = params.promptId { payload["promptId"] = promptId }
        if let sessionKey = params.sessionKey { payload["sessionKey"] = sessionKey }
        if let gatewayStableID = params.gatewayStableID { payload["gatewayStableID"] = gatewayStableID }
        if let kind = params.kind { payload["kindName"] = kind }
        if let details = params.details { payload["details"] = details }
        if let expiresAtMs = params.expiresAtMs { payload["expiresAtMs"] = expiresAtMs }
        if let risk = params.risk { payload["risk"] = risk }
        if let actions = params.actions {
            payload["actions"] = actions.map {
                var a: [String: Any] = ["id": $0.id, "label": $0.label]
                if let style = $0.style { a["style"] = style }
                return a
            }
        }

        let reachable = session.isReachable
        if reachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(payload)
        }
        return NotifyResult(
            deliveredImmediately: reachable,
            queuedForDelivery: !reachable,
            transport: reachable ? "watchConnectivity" : "userInfo"
        )
    }
}
