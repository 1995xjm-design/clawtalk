import SwiftUI
import UIKit

/// 微信扫码绑定页：展示后端下发的二维码，每 3 秒轮询一次绑定状态。
///
/// 后端接口契约（wechatBridgeURL 为配置的桥接服务地址）：
/// - POST {wechatBridgeURL}/api/wechat/qrcode
///   → {"qrcode": "...", "img_base64": "..."}
/// - POST {wechatBridgeURL}/api/wechat/qrcode/status  body {"qrcode":"..."}
///   → {"status":"wait|scaned|need_verifycode|expired|login_success","verify_code":...}
struct WechatBindView: View {
    let bridgeURL: String
    @Environment(\.dismiss) private var dismiss

    private enum BindState: Equatable {
        case loading
        case waiting
        case scanned
        case needVerifyCode(String)
        case success
        case expired
        case failed(String)

        /// 轮询遇到终态后停止
        var isTerminal: Bool {
            switch self {
            case .success, .expired, .failed: return true
            default: return false
            }
        }
    }

    @State private var state: BindState = .loading
    @State private var qrcode: String?
    @State private var qrImage: UIImage?
    @State private var pollTask: Task<Void, Never>?

    private struct QRCodeResponse: Decodable {
        let qrcode: String?
        let img_base64: String?
    }

    private struct QRStatusResponse: Decodable {
        let status: String?
        let verify_code: String?
    }

    private enum WechatBindError: LocalizedError {
        case http(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(let code):
                return "微信桥接服务返回错误（HTTP \(code)）"
            case .invalidResponse:
                return "微信桥接服务返回数据格式不正确"
            }
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            switch state {
            case .loading:
                ProgressView("正在获取二维码…")

            case .waiting, .scanned, .needVerifyCode:
                qrImageView
                statusLabel
                Text("请使用微信扫描二维码完成绑定，每 3 秒自动检查状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("绑定成功")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("现在可以通过微信与 CLAW bot 对话了。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.openClawRed)

            case .expired:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                Text("二维码已过期")
                    .font(.title3)
                Text("请点击下方按钮重新获取二维码。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("重新获取") {
                    fetchQRCode()
                }
                .buttonStyle(.borderedProminent)
                .tint(.openClawRed)

            case .failed(let message):
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("重试") {
                    fetchQRCode()
                }
                .buttonStyle(.borderedProminent)
                .tint(.openClawRed)
            }

            Spacer()
        }
        .navigationTitle("连接微信")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            fetchQRCode()
        }
        .onDisappear {
            stopPolling()
        }
    }

    // MARK: - QR Code

    @ViewBuilder
    private var qrImageView: some View {
        if let image = qrImage {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
                .padding(12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let qr = qrcode, let url = URL(string: qr) {
            // 服务端未返回 base64 图片时，尝试把 qrcode 当图片 URL 加载
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                case .failure:
                    Image(systemName: "qrcode")
                        .font(.system(size: 120))
                        .foregroundStyle(.secondary)
                case .empty:
                    ProgressView()
                @unknown default:
                    EmptyView()
                }
            }
            .padding(12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 120))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state {
        case .waiting:
            Label("等待扫码", systemImage: "qrcode.viewfinder")
                .font(.headline)
        case .scanned:
            Label("已扫码，请在手机上确认登录", systemImage: "iphone")
                .font(.headline)
        case .needVerifyCode(let code):
            VStack(spacing: 8) {
                Text("需要输入验证码")
                    .font(.headline)
                Text(code)
                    .font(.title3.monospaced())
                    .bold()
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Networking

    @MainActor
    private func fetchQRCode() {
        stopPolling()
        state = .loading
        qrcode = nil
        qrImage = nil

        let base = bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let url = URL(string: base + "/api/wechat/qrcode") else {
            state = .failed("微信桥接服务地址未配置")
            return
        }

        Task {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("{}".utf8)
                request.timeoutInterval = 15

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw WechatBindError.http(status)
                }

                let decoded = try JSONDecoder().decode(QRCodeResponse.self, from: data)
                guard let qr = decoded.qrcode, !qr.isEmpty else {
                    throw WechatBindError.invalidResponse
                }
                qrcode = qr
                if let b64 = decoded.img_base64, !b64.isEmpty,
                   let imageData = Data(base64Encoded: b64),
                   let image = UIImage(data: imageData) {
                    qrImage = image
                }

                state = .waiting
                startPolling()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func checkBindingStatus() async {
        guard let qr = qrcode, !qr.isEmpty else { return }
        let base = bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base + "/api/wechat/qrcode/status") else { return }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["qrcode": qr])
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw WechatBindError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
            }

            let decoded = try JSONDecoder().decode(QRStatusResponse.self, from: data)
            switch decoded.status ?? "" {
            case "wait":
                state = .waiting
            case "scaned":
                state = .scanned
            case "need_verifycode":
                state = .needVerifyCode(decoded.verify_code ?? "")
            case "expired":
                state = .expired
                stopPolling()
            case "login_success":
                state = .success
                stopPolling()
            default:
                break
            }
        } catch {
            // 单次轮询失败不打断流程，保持当前状态等待下一次轮询
        }
    }

    @MainActor
    private func startPolling() {
        stopPolling()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await self.checkBindingStatus()
                if self.state.isTerminal {
                    break
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}