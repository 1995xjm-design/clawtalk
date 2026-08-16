import Foundation

/// Manual gateway credential override (mirrors official
/// `GatewayConnectionController+ManualAuth.ManualAuthOverride`).
/// Used for扫码配对/setup links: keeps explicit credentials endpoint-scoped so a
/// new host never falls back to credentials stored for the previous gateway.
struct GatewayManualAuthOverride: Equatable {
    struct SetupAuth {
        let token: String
        let bootstrapToken: String
        let password: String
        let targetStableID: String

        var hasBootstrapToken: Bool {
            !self.bootstrapToken.isEmpty
        }

        var manualAuthOverride: GatewayManualAuthOverride {
            GatewayManualAuthOverride.explicit(
                token: self.token,
                bootstrapToken: self.bootstrapToken,
                password: self.password,
                targetStableID: self.targetStableID,
                suppressStoredDeviceAuth: true)
        }
    }

    let token: String?
    let bootstrapToken: String?
    let password: String?
    let targetStableID: String?
    let suppressStoredDeviceAuth: Bool

    static func explicit(
        token: String?,
        bootstrapToken: String?,
        password: String?,
        targetStableID: String? = nil,
        suppressStoredDeviceAuth: Bool) -> GatewayManualAuthOverride
    {
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedBootstrapToken = bootstrapToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GatewayManualAuthOverride(
            token: trimmedToken.isEmpty ? nil : trimmedToken,
            bootstrapToken: trimmedBootstrapToken.isEmpty ? nil : trimmedBootstrapToken,
            password: trimmedPassword.isEmpty ? nil : trimmedPassword,
            targetStableID: targetStableID,
            suppressStoredDeviceAuth: suppressStoredDeviceAuth)
    }

    static func normalized(
        token: String?,
        bootstrapToken: String?,
        password: String?) -> GatewayManualAuthOverride?
    {
        let override = GatewayManualAuthOverride.explicit(
            token: token,
            bootstrapToken: bootstrapToken,
            password: password,
            suppressStoredDeviceAuth: false)
        guard override.token != nil || override.bootstrapToken != nil || override.password != nil
        else { return nil }
        return override
    }

    static func currentManualInput(
        token: String?,
        pendingOverride: GatewayManualAuthOverride?,
        password: String?,
        targetStableID: String? = nil) -> GatewayManualAuthOverride?
    {
        guard let pendingOverride else {
            return GatewayManualAuthOverride.normalized(token: token, bootstrapToken: nil, password: password)
        }
        if let pendingTarget = pendingOverride.targetStableID,
           !GatewayStableIdentifier.matches(pendingTarget, targetStableID)
        {
            let normalizedInput = GatewayManualAuthOverride.explicit(
                token: token,
                bootstrapToken: nil,
                password: password,
                targetStableID: targetStableID,
                suppressStoredDeviceAuth: true)
            return GatewayManualAuthOverride.explicit(
                token: normalizedInput.token == pendingOverride.token ? nil : normalizedInput.token,
                bootstrapToken: nil,
                password: normalizedInput.password == pendingOverride.password ? nil : normalizedInput.password,
                targetStableID: targetStableID,
                suppressStoredDeviceAuth: true)
        }
        return GatewayManualAuthOverride.explicit(
            token: token,
            bootstrapToken: pendingOverride.bootstrapToken,
            password: password,
            targetStableID: pendingOverride.targetStableID,
            suppressStoredDeviceAuth: pendingOverride.suppressStoredDeviceAuth)
    }

    /// Official stable ID scheme for manually-configured gateways.
    static func manualStableID(host: String, port: Int) -> String {
        "manual|\(host.lowercased())|\(port)"
    }

    static func setupAuth(from link: GatewayConnectDeepLink) -> SetupAuth {
        SetupAuth(
            token: link.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            bootstrapToken: link.bootstrapToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            password: link.password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            targetStableID: self.manualStableID(host: link.host, port: link.port))
    }
}
