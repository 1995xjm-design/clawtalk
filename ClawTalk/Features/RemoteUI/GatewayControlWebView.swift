import SwiftUI

/// 网关控制页面共用壳（Desktop / Terminal）：
/// 从 SettingsStore 网关地址构建 https://host:port/?view=xxx，并注入控制凭证。
struct GatewayControlWebView: View {
    let store: SettingsStore
    let viewName: String
    var title: String

    private var baseURL: String {
        store.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var builtURL: URL? {
        guard !baseURL.isEmpty, let components = URLComponents(string: baseURL) else { return nil }
        var result = components
        switch result.scheme?.lowercased() {
        case "wss":
            result.scheme = "https"
        case "ws":
            result.scheme = "http"
        case "http", "https":
            break
        default:
            result.scheme = "https"
        }
        result.queryItems = [URLQueryItem(name: "view", value: viewName)]
        return result.url
    }

    var body: some View {
        Group {
            if let url = builtURL {
                ControlUIWebView(url: url, authToken: store.gatewayToken)
                    .id(url.absoluteString)
            } else {
                ContentUnavailableView(
                    "无法打开网关页面",
                    systemImage: "network.slash",
                    description: Text("请先在设置中配置网关地址。")
                )
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}