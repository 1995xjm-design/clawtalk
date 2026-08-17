import SwiftUI
import WebKit

/// 官方网关控制 UI 的 WebView 壳（Desktop / Terminal 共用）：
/// - nonPersistent dataStore（不落盘，避免跨网关脏数据）
/// - document-start 注入 `window.__OPENCLAW_NATIVE_CONTROL_AUTH__`（凭证不进 URL）
/// - 同 authority 导航锁定（只允许加载与目标网关同 host/port 的页面）
struct ControlUIWebView: UIViewRepresentable {
    let url: URL
    var authToken: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedHost: url.host, allowedPort: url.port)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        if let authToken, !authToken.isEmpty {
            let payload: [String: Any] = ["token": authToken]
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let scriptSource = "window.__OPENCLAW_NATIVE_CONTROL_AUTH__ = \(jsonString);"
                let script = WKUserScript(
                    source: scriptSource,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
                config.userContentController.addUserScript(script)
            }
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.keyboardDismissMode = .interactive
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 网关地址变化时重建（外层用 .id(url) 触发）；地址未变不重复加载
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let allowedHost: String?
        let allowedPort: Int?

        init(allowedHost: String?, allowedPort: Int?) {
            self.allowedHost = allowedHost
            self.allowedPort = allowedPort
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .formSubmitted {
                let sameHost = target.host == allowedHost
                let samePort = target.port == allowedPort
                if sameHost && samePort {
                    decisionHandler(.allow)
                } else {
                    decisionHandler(.cancel)
                }
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // 错误态由外层视图统一提示（didFail 后 SwiftUI 层显示重试）
        }
    }
}