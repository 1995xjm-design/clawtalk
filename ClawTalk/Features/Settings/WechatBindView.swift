import SwiftUI
import UIKit
import CoreImage
import Photos

/// 微信扫码绑定页：展示后端下发的二维码，每 3 秒轮询一次绑定状态。
///
/// 后端接口契约（wechatBridgeURL 为配置的桥接服务地址）：
/// - POST {wechatBridgeURL}/api/wechat/qrcode
///   → {"qrcode": "...", "img_base64": "..."}
/// - POST {wechatBridgeURL}/api/wechat/qrcode/status  body {"qrcode":"..."}
///   → {"status":"wait|scaned|need_verifycode|expired|login_success","verify_code":...}
struct WechatBindView: View {
    let settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var gatewayURL: String {
        settings.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private var gatewayToken: String { settings.gatewayToken }

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
    @State private var connected: Bool = UserDefaults.standard.bool(forKey: "clawtalk_wechat_connected")
    @State private var showSaveHint = false
    @State private var isConfirming = false
    @State private var confirmMessage: String?

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
                ProgressView("正在让 OpenClaw 生成二维码，首次约需 1 分钟…")

            case .waiting, .scanned, .needVerifyCode:
                qrImageView
                statusLabel
                Text("请用微信扫描二维码完成连接。\n扫码后在微信上确认，然后回到本页点「绑定成功」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                HStack(spacing: 16) {
                    Button {
                        saveQRCodeImage()
                    } label: {
                        Label("保存图片", systemImage: "square.and.arrow.down")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .tint(.openClawRed)
                    Button {
                        confirmMessage = nil
                        isConfirming = true
                        Task {
                            let msg = await checkBindingStatus()
                            isConfirming = false
                            if let msg {
                                confirmMessage = msg
                            }
                        }
                    } label: {
                        if isConfirming {
                            HStack(spacing: 6) {
                                ProgressView()
                                Text("正在确认…")
                            }
                            .font(.subheadline)
                        } else {
                            Label("绑定成功", systemImage: "checkmark.circle")
                                .font(.subheadline)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.openClawRed)
                    .disabled(isConfirming)
                }
                if showSaveHint {
                    Text("二维码已保存到相册")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let confirmMessage {
                    Text(confirmMessage)
                        .font(.caption)
                        .foregroundStyle(confirmMessage.contains("尚未") || confirmMessage.contains("失败") ? .red : .secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("微信 Claw Bot 已连接")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("现在可以通过微信与 Claw Bot 对话了。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("重新生成二维码") {
                    UserDefaults.standard.set(false, forKey: "clawtalk_wechat_connected")
                    connected = false
                    fetchQRCode()
                }
                .buttonStyle(.bordered)
                .tint(.openClawRed)
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.openClawRed)

            case .expired:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
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
                    .font(.largeTitle)
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
            if connected {
                state = .success
            } else {
                fetchQRCode()
            }
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
                        .font(.largeTitle)
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
                .font(.largeTitle)
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

        guard !gatewayURL.isEmpty else {
            LogCollector.record(module: "微信", "连接失败")
                    state = .failed("未配置网关地址，请先在设置中填写网关地址和令牌。")
            return
        }

        InstructionChannels.ensureChannel(name: "微信 Claw Bot", systemEmoji: "💬", sessionKey: InstructionChannels.wechatBind)

        let instruction = "请生成微信 Claw Bot（openclaw-weixin 渠道）的连接二维码，按以下步骤执行：\n1. 找到 OpenClaw 命令行入口（优先 PATH 中 openclaw 命令，找不到则在安装目录搜索 gateway-bundle.mjs 或 index.js）。\n2. 运行渠道登录命令：openclaw channels login --channel openclaw-weixin（node 入口则为 node <入口> channels login --channel openclaw-weixin），需要交互式终端请用 PTY 方式运行并等待输出。\n3. 从输出中提取一次性登录链接（形如 https://liteapp.weixin.qq.com/q/...?qrcode=...&bot_type=3）。\n4. 回复我：只输出这个登录链接本身，不要其他任何内容。"

        Task {
            do {
                let reply = try await OpenClawClient().chat(
                    messages: [Message(role: .user, content: instruction)],
                    gatewayURL: gatewayURL,
                    token: gatewayToken,
                    sessionKey: InstructionChannels.wechatBind
                )
                guard let link = Self.extractLoginLink(from: reply) else {
                    LogCollector.record(module: "微信", "连接失败")
                    state = .failed("未从 OpenClaw 回复中提取到二维码链接，请重试。")
                    return
                }
                qrcode = link
                qrImage = Self.makeQRCodeImage(content: link)
                state = .waiting
                startPolling()
            } catch {
                LogCollector.record(module: "微信", "连接失败")
                    state = .failed("指令执行失败：\(error.localizedDescription)")
            }
        }
    }

    @MainActor
    @discardableResult
    private func checkBindingStatus() async -> String? {
        guard !gatewayURL.isEmpty else { return "网关未配置" }
        let instruction = "请查询微信 Claw Bot（openclaw-weixin 渠道）的扫码登录状态，按以下步骤执行：\n1. 查找微信渠道账户目录（如 openclaw-weixin/accounts/），查看账户文件（*.json）是否存在及其内容。\n2. 判断状态：无账户文件或没有有效 token → 返回 wait；有账户文件且渠道已上线 → 返回 login_success；无法判断时运行 openclaw channels list 确认渠道 enabled/online。\n3. 回复格式固定为一行：wait 或 scanned 或 login_success。"

        do {
            let reply = try await OpenClawClient().chat(
                messages: [Message(role: .user, content: instruction)],
                gatewayURL: gatewayURL,
                token: gatewayToken,
                sessionKey: InstructionChannels.wechatBind
            )
            let lower = reply.lowercased()
            if lower.contains("login_success") {
                state = .success
                UserDefaults.standard.set(true, forKey: "clawtalk_wechat_connected")
                stopPolling()
            } else if lower.contains("scaned") {
                state = .scanned
                return nil
            } else {
                state = .waiting
                return "尚未检测到绑定成功，请确认已在微信上完成登录后重试。"
            }
        } catch {
            // 单次轮询失败不打断流程，保持当前状态等待下一次
            return "查询失败：\(error.localizedDescription)"
        }
        return nil
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

    /// 保存二维码图片到相册
    private func saveQRCodeImage() {
        guard let image = qrImage else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }) { success, error in
                    DispatchQueue.main.async {
                        if success {
                            self.showSaveHint = true
                        } else {
                            LogCollector.record(module: "相册", "保存二维码到相册失败：\(error?.localizedDescription ?? "未知错误")")
                        }
                    }
                }
            default:
                LogCollector.record(module: "相册", "保存二维码失败：没有相册写入权限")
            }
        }
    }

    /// 从 OpenClaw 回复文本中提取一次性登录链接
    static func extractLoginLink(from text: String) -> String? {
        let pattern = #"https://liteapp\.weixin\.qq\.com/q/[^\s"'》]+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 用 CoreImage 本地生成二维码图片（不依赖后端返回 base64/图片）。
    static func makeQRCodeImage(content: String, size: CGFloat = 240) -> UIImage? {
        let data = Data(content.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scale = size / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
