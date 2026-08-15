import Foundation

/// 网关连接端点（官方 GatewayConnectEndpoint 的宿主等价实现）。
struct GatewayConnectEndpoint: Codable, Equatable, Sendable {
    let host: String
    let port: Int
    let tls: Bool

    init(host: String, port: Int, tls: Bool) {
        self.host = host
        self.port = port
        self.tls = tls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decodeIfPresent(Int.self, forKey: .port)
            ?? 0
        self.tls = try container.decodeIfPresent(Bool.self, forKey: .tls)
            ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, tls
    }
}

/// 官方 openclaw qr / 深链生成的配对信息（GatewayConnectDeepLink 宿主等价实现）。
///
/// 兼容两种载荷形状：
/// - `{"url":"wss://host:port","urls":[...],"bootstrapToken":...,"token":...,"password":...}`
/// - `{"host":"...","port":443,"tls":true,"bootstrapToken":...,"token":...,"password":...}`
///
/// 同时支持：base64url 编码的 JSON、原始 JSON、`openclaw://gateway?` 深链、
/// 原始 ws(s):// 网关地址、以及含 `Setup code:` 行的复制文本。
struct GatewayConnectDeepLink: Decodable, Equatable, Sendable {
    let host: String
    let port: Int
    let tls: Bool
    let bootstrapToken: String?
    let token: String?
    let password: String?
    let fallbackEndpoints: [GatewayConnectEndpoint]

    init(
        host: String,
        port: Int,
        tls: Bool,
        bootstrapToken: String?,
        token: String?,
        password: String?,
        fallbackEndpoints: [GatewayConnectEndpoint] = []
    ) {
        self.host = host
        self.port = port
        self.tls = tls
        self.bootstrapToken = bootstrapToken
        self.token = token
        self.password = password
        self.fallbackEndpoints = fallbackEndpoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let hostShapeHost = try container.decodeIfPresent(String.self, forKey: .host)
        let hostShapePort = try container.decodeIfPresent(Int.self, forKey: .port)
        let hostShapeTLS = try container.decodeIfPresent(Bool.self, forKey: .tls)

        let urlShapeURL = try container.decodeIfPresent(String.self, forKey: .url)
        let urlShapeURLs = try container.decodeIfPresent([String].self, forKey: .urls)

        let primaryURL = urlShapeURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraURLs = (urlShapeURLs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var endpoints: [GatewayConnectEndpoint] = []
        var primaryHost: String?
        var primaryPort: Int?
        var primaryTLS = false

        if let primaryURL, !primaryURL.isEmpty {
            if let parsed = Self.endpoint(from: primaryURL) {
                endpoints.append(parsed)
                primaryHost = parsed.host
                primaryPort = parsed.port
                primaryTLS = parsed.tls
            }
        }
        for extra in extraURLs where !extra.isEmpty {
            if let parsed = Self.endpoint(from: extra),
               !endpoints.contains(where: { $0.host == parsed.host && $0.port == parsed.port }) {
                endpoints.append(parsed)
            }
        }

        let hostValue: String
        if let hostShapeHost, !hostShapeHost.isEmpty {
            hostValue = hostShapeHost
            primaryHost = hostValue
            primaryTLS = hostShapeTLS ?? primaryTLS
            primaryPort = hostShapePort
        } else if let primaryHost {
            hostValue = primaryHost
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "配对码缺少 host 或 url 字段"))
        }

        let portValue = primaryPort ?? (primaryTLS ? 443 : 80)
        guard (1...65535).contains(portValue) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "端口无效: \(portValue)"))
        }

        // 回退端点：把 url(s) 中非主端点并入；host 形状则沿用传入值
        var fallback: [GatewayConnectEndpoint] = endpoints
        if let first = endpoints.first,
           !(first.host == hostValue && first.port == portValue) {
            fallback.insert(GatewayConnectEndpoint(host: hostValue, port: portValue, tls: primaryTLS), at: 0)
        }
        if endpoints.isEmpty {
            fallback = []
        }

        self.host = hostValue
        self.port = portValue
        self.tls = primaryTLS
        self.bootstrapToken = try container.decodeIfPresent(String.self, forKey: .bootstrapToken)
        self.token = try container.decodeIfPresent(String.self, forKey: .token)
        self.password = try container.decodeIfPresent(String.self, forKey: .password)
        self.fallbackEndpoints = try container.decodeIfPresent([GatewayConnectEndpoint].self, forKey: .fallbackEndpoints)
            ?? fallback
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, tls, bootstrapToken, token, password
        case url, urls, fallbackEndpoints
    }

    // MARK: - 派生值

    /// 主连接 WebSocket 地址。
    var websocketURL: URL? {
        var components = URLComponents()
        components.scheme = tls ? "wss" : "ws"
        components.host = host
        components.port = port
        return components.url
    }

    /// 网关 HTTP(S) 地址（用于写入 App 网关配置）。
    var httpGatewayURL: String {
        var components = URLComponents()
        components.scheme = tls ? "https" : "http"
        components.host = host
        components.port = port
        return components.string ?? "\(tls ? "https" : "http")://\(host):\(port)"
    }

    /// 网关 stableID：与官方 manual 网关一致（manual|<host>|<port>），
    /// 用于把设备令牌与具体网关绑定，换网关/换电脑后重新配对不串号。
    var stableID: String {
        "manual|\(host.lowercased())|\(port)"
    }

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }

    // MARK: - 解析入口

    /// 解析任意来源的配对输入（扫码/粘贴/深链/原始 ws 地址）。
    static func fromSetupInput(_ input: String) -> GatewayConnectDeepLink? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = extractSetupCode(from: trimmed) ?? trimmed
        if let link = fromJSON(candidate) { return link }
        if let link = fromDeepLink(trimmed) { return link }
        return fromGatewayURLString(candidate)
    }

    /// 从复制文本中提取 `Setup code:` 行（官方粘贴场景）。
    private static func extractSetupCode(from text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.contains("setup code") || lower.contains("配对码") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let colon = trimmed.firstIndex(of: ":") {
                    let value = trimmed[trimmed.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { return value }
                }
            }
        }
        return nil
    }

    /// base64url 编码 JSON 或原始 JSON。
    private static func fromJSON(_ candidate: String) -> GatewayConnectDeepLink? {
        let data: Data?
        if let decoded = base64URLDecode(candidate) {
            data = decoded
        } else {
            data = candidate.data(using: .utf8)
        }
        guard let payload = data,
              let link = try? JSONDecoder().decode(GatewayConnectDeepLink.self, from: payload),
              link.isValid
        else { return nil }
        return link
    }

    /// `openclaw://gateway?host=...&port=...&tls=true&token=...` 深链。
    private static func fromDeepLink(_ input: String) -> GatewayConnectDeepLink? {
        guard let url = URL(string: input),
              url.scheme?.lowercased() == "openclaw",
              url.host?.lowercased() == "gateway",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name] = value }
        }
        guard let host = query["host"], !host.isEmpty else { return nil }
        let port = query["port"].flatMap { Int($0) } ?? 443
        let tls = query["tls"].flatMap { Bool($0) } ?? true
        return GatewayConnectDeepLink(
            host: host,
            port: port,
            tls: tls,
            bootstrapToken: query["bootstrapToken"],
            token: query["token"],
            password: query["password"])
    }

    /// 原始 ws(s):// 网关地址。
    private static func fromGatewayURLString(_ input: String) -> GatewayConnectDeepLink? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              let host = url.host, !host.isEmpty
        else { return nil }
        let tls = scheme == "wss"
        let port = url.port ?? (tls ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        return GatewayConnectDeepLink(
            host: host,
            port: port,
            tls: tls,
            bootstrapToken: nil,
            token: nil,
            password: nil)
    }

    private static func endpoint(from urlString: String) -> GatewayConnectEndpoint? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" || scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        let tls = scheme == "wss" || scheme == "https"
        let port = url.port ?? (tls ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        return GatewayConnectEndpoint(host: host, port: port, tls: tls)
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }
}
