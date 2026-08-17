import CryptoKit
import Foundation

/// 推送注册管理器（对齐官方 PushRegistrationManager 精简版）：
/// direct（websocket 直达）与 relay（中继）两种 payload 生成，relay 复用 Keychain 缓存注册状态。
enum PushDistributionMode: String, Codable {
    case official
    case custom
}

enum PushRelayProfile: String, Codable {
    case production
    case deviceSandbox = "device-sandbox"
    case simulatorSandbox = "simulator-sandbox"
}

enum PushProofPolicy: String, Codable {
    case appleStrict = "apple-strict"
    case appleDevelopment = "apple-development"
    case internalSimulator = "internal-simulator"
}

private struct DirectGatewayPushRegistrationPayload: Encodable {
    var transport: String = PushTransportMode.direct.rawValue
    var token: String
    var topic: String
    var environment: String
}

private struct RelayGatewayPushRegistrationPayload: Encodable {
    var transport: String = PushTransportMode.relay.rawValue
    var relayHandle: String
    var sendGrant: String
    var gatewayDeviceId: String
    var installationId: String
    var topic: String
    var environment: String
    var distribution: String
    var relayOrigin: String
    var tokenDebugSuffix: String?
}

actor PushRegistrationManager {
    private let buildConfig: PushBuildConfig
    private let relayClient: PushRelayClient?

    var usesRelayTransport: Bool { buildConfig.transport == .relay }

    init(buildConfig: PushBuildConfig = .load()) {
        self.buildConfig = buildConfig
        self.relayClient = buildConfig.relayBaseURL.map { PushRelayClient(baseURL: $0) }
    }

    /// 生成网关注册 payload：direct 直接编码；relay 走缓存或重新注册。
    func makeGatewayRegistrationPayload(
        apnsTokenHex: String,
        topic: String,
        gatewayIdentity: PushRelayGatewayIdentity?) async throws -> String
    {
        switch buildConfig.transport {
        case .direct:
            return try Self.encodePayload(DirectGatewayPushRegistrationPayload(
                token: apnsTokenHex,
                topic: topic,
                environment: buildConfig.environment.rawValue))
        case .relay:
            guard let gatewayIdentity else {
                throw PushRelayError.relayMisconfigured("Missing gateway identity for relay registration")
            }
            return try await makeRelayPayload(
                apnsTokenHex: apnsTokenHex,
                topic: topic,
                gatewayIdentity: gatewayIdentity)
        }
    }

    private func makeRelayPayload(
        apnsTokenHex: String,
        topic: String,
        gatewayIdentity: PushRelayGatewayIdentity) async throws -> String
    {
        guard buildConfig.mode == .relay else {
            throw PushRelayError.relayMisconfigured("Relay transport requires relay build mode")
        }
        guard let relayClient else {
            throw PushRelayError.relayBaseURLMissing
        }
        guard let bundleId = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleId.isEmpty
        else {
            throw PushRelayError.relayMisconfigured("Missing bundle identifier for relay registration")
        }
        guard let installationId = SettingsStore.loadStableInstanceID()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !installationId.isEmpty
        else {
            throw PushRelayError.relayMisconfigured("Missing stable installation ID for relay registration")
        }

        let tokenHashHex = Self.sha256Hex(apnsTokenHex)
        let relayOrigin = relayClient.normalizedBaseURLString
        let profile = buildConfig.profile.rawValue
        let proof = buildConfig.proofPolicy.rawValue

        if let stored = PushRelayRegistrationStore.loadRegistrationState(),
           PushRelayRegistrationStore.isValid(
            stored,
            installationId: installationId,
            gatewayDeviceId: gatewayIdentity.deviceId,
            relayOrigin: relayOrigin,
            apnsEnvironment: buildConfig.environment.rawValue,
            relayProfile: profile,
            proofPolicy: proof,
            apnsTokenHex: tokenHashHex)
        {
            return try Self.encodePayload(RelayGatewayPushRegistrationPayload(
                relayHandle: stored.relayHandle,
                sendGrant: stored.sendGrant,
                gatewayDeviceId: gatewayIdentity.deviceId,
                installationId: installationId,
                topic: topic,
                environment: buildConfig.environment.rawValue,
                distribution: buildConfig.distribution.rawValue,
                relayOrigin: relayOrigin,
                tokenDebugSuffix: stored.tokenDebugSuffix))
        }

        let response = try await relayClient.register(PushRelayRegisterRequest(
            deviceId: gatewayIdentity.deviceId,
            apnsToken: apnsTokenHex,
            gatewayURL: nil,
            gatewayToken: nil,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            environment: buildConfig.environment.rawValue))
        let state = PushRelayRegistrationStore.RegistrationState(
            relayHandle: response.relayHandle ?? "",
            sendGrant: response.sendGrant ?? "",
            relayOrigin: relayOrigin,
            gatewayDeviceId: gatewayIdentity.deviceId,
            relayHandleExpiresAtMs: nil,
            tokenDebugSuffix: response.tokenSuffix,
            lastAPNsTokenHashHex: tokenHashHex,
            installationId: installationId,
            lastTransport: buildConfig.transport.rawValue,
            apnsEnvironment: buildConfig.environment.rawValue,
            relayProfile: profile,
            proofPolicy: proof)
        PushRelayRegistrationStore.saveRegistrationState(state)
        return try Self.encodePayload(RelayGatewayPushRegistrationPayload(
            relayHandle: response.relayHandle ?? "",
            sendGrant: response.sendGrant ?? "",
            gatewayDeviceId: gatewayIdentity.deviceId,
            installationId: installationId,
            topic: topic,
            environment: buildConfig.environment.rawValue,
            distribution: buildConfig.distribution.rawValue,
            relayOrigin: relayOrigin,
            tokenDebugSuffix: state.tokenDebugSuffix))
    }

    static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func encodePayload(_ payload: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PushRelayError.relayMisconfigured("Failed to encode push registration payload as UTF-8")
        }
        return json
    }
}
