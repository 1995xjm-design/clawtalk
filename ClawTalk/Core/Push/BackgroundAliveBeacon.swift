import Foundation
import UIKit

/// 后台存活信标（对齐官方 BackgroundAliveBeacon）：node.presence.alive 事件，
/// 后台/静默推送/后台刷新/连接成功时上报，10 分钟节流避免刷屏。
enum BackgroundAliveBeacon {
    static let eventName = "node.presence.alive"
    static let minSuccessIntervalSeconds: TimeInterval = 10 * 60

    enum Trigger: String, CaseIterable, Codable {
        case background
        case silentPush = "silent_push"
        case bgAppRefresh = "bg_app_refresh"
        case significantLocation = "significant_location"
        case manual
        case connect
    }

    struct Payload: Encodable {
        var trigger: String
        var sentAtMs: Int64
        var displayName: String
        var version: String
        var platform: String
        var deviceFamily: String
        var modelIdentifier: String
        var pushTransport: String?
    }

    struct NodeEventRequestPayload: Codable {
        var event: String = BackgroundAliveBeacon.eventName
        var payloadJSON: String
    }

    static func normalizeTrigger(_ raw: String) -> Trigger {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Trigger(rawValue: normalized) ?? .background
    }

    static func shouldSkipRecentSuccess(
        isGatewayConnected: Bool,
        now: Date,
        lastSuccessAtMs: Double?,
        minInterval: TimeInterval = Self.minSuccessIntervalSeconds) -> Bool
    {
        guard isGatewayConnected else { return false }
        guard let lastSuccessAtMs, lastSuccessAtMs > 0 else { return false }
        let elapsed = now.timeIntervalSince1970 - (lastSuccessAtMs / 1000.0)
        return elapsed >= 0 && elapsed < minInterval
    }

    @MainActor
    static func makePayload(trigger: Trigger, displayName: String, pushTransport: String?) -> Payload {
        let device = UIDevice.current
        return Payload(
            trigger: trigger.rawValue,
            sentAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            displayName: displayName,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            platform: "ios",
            deviceFamily: device.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            modelIdentifier: Self.modelIdentifier(),
            pushTransport: pushTransport)
    }

    static func makeNodeEventRequestPayloadJSON(
        payload: Payload,
        encoder: JSONEncoder = JSONEncoder()) throws -> String
    {
        let payloadData = try encoder.encode(payload)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw EncodingError.invalidValue(payload, EncodingError.Context(
                codingPath: [], debugDescription: "Failed to encode background alive payload as UTF-8"))
        }
        let requestData = try encoder.encode(NodeEventRequestPayload(payloadJSON: payloadJSON))
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw EncodingError.invalidValue(payload, EncodingError.Context(
                codingPath: [], debugDescription: "Failed to encode background alive request as UTF-8"))
        }
        return requestJSON
    }

    private static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}
