import Foundation
import WebKit
import UIKit

/// Manages an agent-controlled WKWebView canvas.
/// Commands are dispatched from NodeConnection; the view is presented in CanvasView.
@Observable
@MainActor
final class CanvasCapability {

    struct PresentResult: Encodable { let ok: Bool }
    struct EvalResult: Encodable { let result: String? }
    enum SnapshotFormat: String {
        case jpeg
        case png
    }

    struct SnapshotResult: Encodable {
        let imageBase64: String
        let width: Int
        let height: Int
        let format: String
    }

    enum CanvasError: LocalizedError {
        case noWebView
        case evalFailed(String)
        case snapshotFailed

        var errorDescription: String? {
            switch self {
            case .noWebView: return "画布不可用——请先打开画布页"
            case .evalFailed(let msg): return "JavaScript 错误：\(msg)"
            case .snapshotFailed: return "画布截图失败"
            }
        }
    }

    // MARK: - State

    private(set) var currentURL: String?
    var isPresented: Bool = false

    /// The WKWebView is set by CanvasView when it appears.
    var webView: WKWebView?
    private var pendingURL: URL?

    // MARK: - Singleton

    static let shared = CanvasCapability()
    private init() {}

    // MARK: - Commands

    func present(url: String) async throws -> PresentResult {
        guard let parsedURL = URL(string: url) else {
            throw CanvasError.evalFailed("无效的 URL：\(url)")
        }

        currentURL = url
        pendingURL = parsedURL
        isPresented = true

        // If webView already exists, load immediately
        if let webView {
            webView.load(URLRequest(url: parsedURL))
            pendingURL = nil
        }
        // Otherwise, CanvasView will pick up pendingURL when it creates the webView

        return PresentResult(ok: true)
    }

    /// Called by CanvasView when the WKWebView is created.
    func webViewReady(_ wv: WKWebView) {
        webView = wv
        if let url = pendingURL {
            wv.load(URLRequest(url: url))
            pendingURL = nil
        }
    }

    func navigate(url: String) async throws -> PresentResult {
        return try await present(url: url)
    }

    /// canvas.hide：收起画布（与 present 的 isPresented 状态对应）。
    func hide() {
        currentURL = nil
        pendingURL = nil
        isPresented = false
    }

    func evalJS(script: String) async throws -> EvalResult {
        guard let webView else { throw CanvasError.noWebView }

        let result = try await webView.evaluateJavaScript(script)
        let resultString: String?
        if let str = result as? String {
            resultString = str
        } else if let num = result as? NSNumber {
            resultString = num.stringValue
        } else if result is NSNull || result == nil {
            resultString = nil
        } else {
            resultString = String(describing: result)
        }

        return EvalResult(result: resultString)
    }

    func snapshot(maxWidth: Int = 1024, quality: Double = 0.8, format: SnapshotFormat = .jpeg) async throws -> SnapshotResult {
        guard let webView else { throw CanvasError.noWebView }

        let config = WKSnapshotConfiguration()
        let image = try await webView.takeSnapshot(configuration: config)

        let resized = resizeImage(image, maxWidth: maxWidth)
        let data: Data?
        switch format {
        case .jpeg: data = resized.jpegData(compressionQuality: quality)
        case .png: data = resized.pngData()
        }
        guard let data else {
            throw CanvasError.snapshotFailed
        }

        return SnapshotResult(
            imageBase64: data.base64EncodedString(),
            width: Int(resized.size.width),
            height: Int(resized.size.height),
            format: format.rawValue
        )
    }

    func reset() {
        currentURL = nil
        webView?.loadHTMLString("", baseURL: nil)
    }

    // MARK: - A2UI (canvas.a2ui.reset / push / pushJSONL)

    /// Evaluate JavaScript and return the raw result string (used by a2ui handlers).
    func evalJSRaw(script: String) async throws -> String {
        guard let webView else { throw CanvasError.noWebView }

        let result = try await webView.evaluateJavaScript(script)
        let resultString: String
        if let str = result as? String {
            resultString = str
        } else if let num = result as? NSNumber {
            resultString = num.stringValue
        } else if result is NSNull || result == nil {
            resultString = "null"
        } else {
            resultString = String(describing: result)
        }
        return resultString
    }

    func a2uiReset() async throws -> String {
        let js = """
        (() => {
          const host = globalThis.openclawA2UI;
          if (!host) return JSON.stringify({ ok: false, error: "missing openclawA2UI" });
          return JSON.stringify(host.reset());
        })()
        """
        return try await evalJSRaw(script: js)
    }

    func a2uiPush(messagesJSON: String) async throws -> String {
        let js = """
        (() => {
          try {
            const host = globalThis.openclawA2UI;
            if (!host) return JSON.stringify({ ok: false, error: "missing openclawA2UI" });
            const messages = \(messagesJSON);
            return JSON.stringify(host.applyMessages(messages));
          } catch (e) {
            return JSON.stringify({ ok: false, error: String(e?.message ?? e) });
          }
        })()
        """
        return try await evalJSRaw(script: js)
    }

    func a2uiPushJSONL(jsonl: String) async throws -> String {
        let messages: [AnyCodable] = jsonl
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> AnyCodable? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let obj = try? JSONDecoder().decode(AnyCodable.self, from: data) else { return nil }
                return obj
            }
        let data = try JSONEncoder().encode(messages)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        return try await a2uiPush(messagesJSON: json)
    }

    // MARK: - Private

    private func resizeImage(_ image: UIImage, maxWidth: Int) -> UIImage {
        let maxW = CGFloat(maxWidth)
        if image.size.width <= maxW { return image }

        let scale = maxW / image.size.width
        let newSize = CGSize(width: maxW, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Params

struct CanvasPresentParams: Decodable {
    let url: String
}

struct CanvasEvalParams: Decodable {
    let javaScript: String?
    let script: String?

    var resolvedScript: String? { javaScript ?? script }
}

struct CanvasSnapshotParams: Decodable {
    let maxWidth: Int?
    let quality: Double?
    let format: String?
}
