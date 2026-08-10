import Foundation

/// 联系人列表服务：GET {gateway}/contacts。
/// 网关未配置时返回空数组（键盘不阻塞）；网络/HTTP/解析失败抛错，由调用方展示空态。
final class ContactListService {

    /// 拉取联系人列表（含画像完整度）。
    static func fetchContacts() async throws -> [ChatContact] {
        do {
            let config = SharedConfig.load()
            guard !config.isEmpty else { return [] }

            let baseURL = config.gatewayURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(baseURL)/contacts") else {
                throw GatewayAPIError.invalidURL
            }
            try GatewaySecurity.validate(url)

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw GatewayAPIError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                throw GatewayAPIError.httpError(http.statusCode, String(preview))
            }

            let decoded = try JSONDecoder().decode(ContactsResponse.self, from: data)
            return decoded.contacts
        } catch {
            KeyboardLogCollector.record(module: "键盘联系人", error.localizedDescription)
            throw error
        }
    }
}

private struct ContactsResponse: Decodable {
    let contacts: [ChatContact]
}