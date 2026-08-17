import Foundation

/// 推送中继注册状态缓存（对齐官方 PushRelayRegistrationStore / PushRelayKeychainStore）：
/// relayHandle / sendGrant 复用，避免每次上报都重新注册；App Attest key id 占位存储。
enum PushRelayRegistrationStore {
    private static let service = "ai.openclawfoundation.app.pushrelay"
    private static let registrationStateAccount = "registration-state"
    private static let appAttestKeyIDAccount = "app-attest-key-id"

    struct RegistrationState: Codable, Equatable {
        var relayHandle: String
        var sendGrant: String
        var relayOrigin: String?
        var gatewayDeviceId: String
        var relayHandleExpiresAtMs: Int64?
        var tokenDebugSuffix: String?
        var lastAPNsTokenHashHex: String
        var installationId: String
        var lastTransport: String
        var apnsEnvironment: String
        var relayProfile: String
        var proofPolicy: String
    }

    static func loadRegistrationState() -> RegistrationState? {
        guard let raw = SecureStorage.shared.getString(serviceKey(registrationStateAccount)),
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(RegistrationState.self, from: data)
    }

    @discardableResult
    static func saveRegistrationState(_ state: RegistrationState) -> Bool {
        guard let data = try? JSONEncoder().encode(state),
              let raw = String(data: data, encoding: .utf8)
        else { return false }
        SecureStorage.shared.setString(raw, forKey: serviceKey(registrationStateAccount))
        return true
    }

    static func clearRegistrationState() {
        SecureStorage.shared.setString(nil, forKey: serviceKey(registrationStateAccount))
    }

    static func loadAppAttestKeyID() -> String? {
        SecureStorage.shared.getString(serviceKey(appAttestKeyIDAccount))
    }

    static func saveAppAttestKeyID(_ keyID: String) {
        SecureStorage.shared.setString(keyID, forKey: serviceKey(appAttestKeyIDAccount))
    }

    /// 判断缓存是否仍有效：installationId / 网关身份 / 环境一致且未过期。
    static func isValid(
        _ state: RegistrationState,
        installationId: String,
        gatewayDeviceId: String,
        relayOrigin: String,
        apnsEnvironment: String,
        relayProfile: String,
        proofPolicy: String,
        apnsTokenHex: String,
        now: Date = Date()) -> Bool
    {
        guard state.installationId == installationId,
              state.gatewayDeviceId == gatewayDeviceId,
              state.relayOrigin == relayOrigin,
              state.apnsEnvironment == apnsEnvironment,
              state.relayProfile == relayProfile,
              state.proofPolicy == proofPolicy,
              state.lastAPNsTokenHashHex == apnsTokenHex
        else { return false }
        guard let expiresAtMs = state.relayHandleExpiresAtMs else { return false }
        // 到期前 60s 视为过期，让重连路径重新发布存活句柄。
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return expiresAtMs > nowMs + 60000
    }

    private static func serviceKey(_ account: String) -> String {
        "\(service).\(account)"
    }
}
