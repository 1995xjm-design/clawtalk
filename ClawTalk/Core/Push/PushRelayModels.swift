import Foundation

/// 推送构建配置（对齐官方 PushBuildConfig）：relay（默认）/direct 双模式 + APNs 环境。
enum PushBuildMode: String, Codable {
    case relay
    case direct
}

enum PushAPNsEnvironment: String, Codable {
    case development
    case production
}

enum PushTransportMode: String, Codable {
    case apns
    case websocket
}

struct PushBuildConfig {
    var mode: PushBuildMode = .relay
    var environment: PushAPNsEnvironment = .production
    var transport: PushTransportMode = .apns
    var relayBaseURL: String?

    /// 读取环境变量/Info.plist 覆盖（默认 relay + production + apns）。
    static func load(defaults: UserDefaults = .standard) -> PushBuildConfig {
        var config = PushBuildConfig()
        if let mode = defaults.string(forKey: "push.build.mode"), let parsed = PushBuildMode(rawValue: mode) {
            config.mode = parsed
        }
        if let env = defaults.string(forKey: "push.apns.environment"), let parsed = PushAPNsEnvironment(rawValue: env) {
            config.environment = parsed
        }
        config.relayBaseURL = defaults.string(forKey: "push.relay.baseURL")
        return config
    }
}

/// 推送注册同意（对齐官方 PushEnrollmentConsent）。
enum PushEnrollmentConsent {
    private static let key = "push.enrollment.consented"

    static var isConsented: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func setConsented(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// PushRelay 注册协议（对齐官方 PushRelayClient）。
struct PushRelayRegisterRequest: Encodable {
    var deviceId: String
    var apnsToken: String
    var gatewayURL: String?
    var gatewayToken: String?
    var appVersion: String?
    var environment: String
}

struct PushRelayRegisterResponse: Codable {
    var ok: Bool?
    var relayId: String?
    var error: String?
}

enum PushRelayError: LocalizedError {
    case invalidRelayURL
    case http(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL: return "推送中继地址无效"
        case .http(let code): return "推送中继 HTTP \(code)"
        case .decoding: return "推送中继响应解析失败"
        }
    }
}

/// 中继注册客户端：POST {relayBase}/v1/push/register 提交 deviceToken。
struct PushRelayClient {
    let baseURL: String

    func register(_ request: PushRelayRegisterRequest) async throws -> PushRelayRegisterResponse {
        guard let url = URL(string: baseURL)?.appendingPathComponent("v1/push/register") else {
            throw PushRelayError.invalidRelayURL
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PushRelayError.http(http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(PushRelayRegisterResponse.self, from: data) else {
            throw PushRelayError.decoding
        }
        return decoded
    }
}