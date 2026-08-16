import SwiftUI
import UIKit

struct OnboardingView: View {
    @Bindable var settingsStore: SettingsStore
    let onComplete: () -> Void

    @State private var step: Step = .welcome
    @State private var gatewayURL = ""
    @State private var gatewayToken = ""
    @State private var connectionState: ConnectionTestState = .idle
    @State private var showScanner = false
    @State private var scanNotice: String?
    @State private var rescanToken = 0
    @State private var showManual = false
    @State private var copiedCommand = false

    enum Step: Int, CaseIterable {
        case welcome = 0
        case gatewaySetup
        case gateway
    }

    enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failed(String)
    }

    var body: some View {
        TabView(selection: $step) {
            welcomeStep.tag(Step.welcome)
            gatewaySetupStep.tag(Step.gatewaySetup)
            gatewayStep.tag(Step.gateway)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .onAppear {
            UIPageControl.appearance().currentPageIndicatorTintColor = UIColor(.openClawRed)
            UIPageControl.appearance().pageIndicatorTintColor = UIColor(.openClawRed).withAlphaComponent(0.3)
        }
        .background(Color(.systemBackground))
        .preferredColorScheme(settingsStore.settings.preferredColorScheme)
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("LogoRed")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)

            Text("欢迎使用 ClawTalk")
                .font(.title)
                .fontWeight(.bold)

            Text("和你的 OpenClaw AI 智能体聊天。\n打字、发图片，或免提语音对话。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            primaryButton("开始使用") {
                withAnimation { step = .gatewaySetup }
            }
            .padding(.bottom, 80)
        }
    }

    // MARK: - Gateway Setup Instructions

    private var gatewaySetupStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.openClawRed)

            Text("需要网关")
                .font(.title2)
                .fontWeight(.bold)

            Text("ClawTalk 需要连接运行在电脑或服务器上的 OpenClaw 网关。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 12) {
                bulletPoint("在电脑上安装 OpenClaw")
                bulletPoint("运行 openclaw onboard 完成配置")
                bulletPoint("在网关配置中开启 HTTP API")
                bulletPoint("设置网关访问令牌")
                bulletPoint("远程访问时开启 HTTPS")
            }
            .padding(.horizontal, 32)

            Link(destination: URL(string: "https://docs.openclaw.ai/gateway")!) {
                HStack(spacing: 6) {
                    Image(systemName: "book.fill")
                    Text("查看设置指南")
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.openClawRed)
            }
            .padding(.top, 4)

            Spacer()

            primaryButton("我已有网关") {
                withAnimation { step = .gateway }
            }

            Button("稍后设置") {
                finishOnboarding()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 60)
        }
    }

    private func bulletPoint(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.openClawRed)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Gateway Config

    private var gatewayStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "qrcode.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(.openClawRed)

            Text("连接网关")
                .font(.title2)
                .fontWeight(.bold)

            Text("在您的 OpenClaw 上运行此命令并扫描二维码")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            qrCommandBox
                .padding(.horizontal, 24)

            primaryButton("扫描二维码") {
                scanNotice = nil
                showScanner = true
            }
            .padding(.top, 4)

            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
                Text("或")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
            }
            .padding(.horizontal, 40)

            HStack(spacing: 24) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showManual.toggle()
                    }
                } label: {
                    Label(showManual ? "收起手动连接" : "手动连接", systemImage: showManual ? "chevron.up" : "chevron.down")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.openClawRed)
                }

                Button {
                    pasteSetupCode()
                } label: {
                    Label("粘贴配对码", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.openClawRed)
                }
            }

            if showManual {
                manualConnectionForm
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            connectionStatusRow
                .padding(.horizontal, 24)

            Spacer()

            bottomActionButton
                .padding(.bottom, 8)

            Button("跳过") {
                finishOnboarding()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 40)
        }
        .animation(.easeInOut(duration: 0.2), value: connectionState)
        .animation(.easeInOut(duration: 0.2), value: showManual)
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerView(
                onScan: { value in
                    handleScannedCode(value)
                },
                onCancel: {
                    showScanner = false
                },
                scanNotice: scanNotice,
                rescanToken: rescanToken
            )
            .ignoresSafeArea()
        }
    }

    /// 「openclaw qr」命令框，可一键复制。
    private var qrCommandBox: some View {
        HStack(spacing: 10) {
            Text("openclaw qr")
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                UIPasteboard.general.string = "openclaw qr"
                copiedCommand = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copiedCommand = false
                }
            } label: {
                Label(copiedCommand ? "已复制" : "复制", systemImage: copiedCommand ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .tint(.openClawRed)
        }
        .padding(14)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 手动连接表单（网关地址 + 访问令牌）。
    private var manualConnectionForm: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("网关地址")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                TextField("网关地址", text: $gatewayURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("访问令牌")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                SecureField("访问令牌", text: $gatewayToken)
                    .textContentType(.password)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 24)
    }

    /// 内联连接测试结果。
    @ViewBuilder
    private var connectionStatusRow: some View {
        if connectionState != .idle {
            HStack(spacing: 8) {
                switch connectionState {
                case .testing:
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("正在测试...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("连接成功！")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                case .failed(let error):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                case .idle:
                    EmptyView()
                }
            }
            .transition(.opacity)
        }
    }

    /// 底部主按钮：配对/连接成功后显示「继续」，手动模式下显示「测试连接」。
    @ViewBuilder
    private var bottomActionButton: some View {
        if connectionState == .success {
            primaryButton("继续") {
                finishOnboarding()
            }
        } else if showManual {
            primaryButton("测试连接") {
                settingsStore.settings.gatewayURL = gatewayURL
                settingsStore.gatewayToken = gatewayToken
                settingsStore.save()
                testConnection()
            }
            .disabled(gatewayURL.isEmpty || gatewayToken.isEmpty || connectionState == .testing)
            .opacity(gatewayURL.isEmpty || gatewayToken.isEmpty ? 0.5 : 1)
        }
    }

    // MARK: - QR Pairing

    private func startScanning() {
        showScanner = true
    }

    private func handleScannedCode(_ raw: String) {
        guard let link = GatewayConnectDeepLink.fromSetupInput(raw) else {
            // 无效配对码：不退出扫码页，显示提示并复位继续扫码
            rescanToken += 1
            scanNotice = "无法识别配对码，请重新扫描"
            connectionState = .failed("无法识别配对码，请重新扫码")
            return
        }
        scanNotice = nil
        showScanner = false
        applySetupCode(link)
    }

    private func pasteSetupCode() {
        guard let raw = UIPasteboard.general.string, !raw.isEmpty else {
            connectionState = .failed("剪贴板为空，请先复制配对码")
            return
        }
        guard let link = GatewayConnectDeepLink.fromSetupInput(raw) else {
            connectionState = .failed("无法识别剪贴板中的配对码")
            return
        }
        applySetupCode(link)
    }

    /// 应用配对码：自动填网关地址、保存令牌/bootstrapToken/stableID，并走 WebSocket 配对测试。
    private func applySetupCode(_ link: GatewayConnectDeepLink) {
        gatewayURL = link.httpGatewayURL
        settingsStore.applyGatewayDeepLink(link)
        connectionState = .testing

        Task { @MainActor in
            await testWebSocketConnection(
                token: link.token,
                bootstrapToken: link.bootstrapToken,
                password: link.password
            )
        }
    }

    /// 用配对码走 WebSocket 握手配对（配对成功即视为连接成功）。
    /// 与官方一致：bootstrap 配对走 role=node 会话（clientMode=node、scopes 为空），
    /// 配对成功后网关下发 node/operator 双角色令牌。
    @MainActor
    private func testWebSocketConnection(token: String?, bootstrapToken: String?, password: String?) async {
        let resolved = settingsStore.settings.resolvedWebSocketURL
        guard !resolved.isEmpty, let wsURL = URL(string: resolved) else {
            connectionState = .failed("无效的网关地址")
            return
        }

        let gateway = GatewayWebSocket(
            url: wsURL,
            token: token,
            bootstrapToken: bootstrapToken,
            password: password,
            role: "node",
            scopes: [],
            caps: NodeConnection.declaredCaps,
            commands: NodeConnection.declaredCommands,
            permissions: await GatewayPermissions.current(),
            displayName: NodeConnection.resolvedNodeDisplayName(),
            clientMode: "node",
            deviceTokenHandler: { [settingsStore] deviceToken in
                Task { @MainActor in
                    // 配对成功：把网关下发的 device token 存为 App 的网关令牌，
                    // 否则工具页/诊断/网关会话拿不到令牌（此前这里一直是空）。
                    settingsStore.gatewayToken = deviceToken
                    settingsStore.save()
                }
            }
        )
        do {
            try await gateway.connect()
            await gateway.shutdown()
            clearConsumedPairingCredential()
            connectionState = .success
        } catch {
            await gateway.shutdown()
            connectionState = .failed(pairingErrorMessage(for: error))
        }
    }

    /// bootstrap 配对码一次性有效，配对成功后清除，避免重连时把已消费的配对码再发出去。
    private func clearConsumedPairingCredential() {
        if settingsStore.settings.bootstrapToken != nil {
            settingsStore.settings.bootstrapToken = nil
            settingsStore.save()
        }
    }

    private func pairingErrorMessage(for error: Error) -> String {
        guard let gatewayError = error as? GatewayWebSocket.GatewayError else {
            return error.localizedDescription
        }
        switch gatewayError {
        case .pairingRequired:
            return "已向网关请求配对。请在电脑上运行 openclaw devices approve 批准后，重新点击连接。"
        case .bootstrapTokenInvalid:
            return "配对码无效或已过期，请重新运行 openclaw qr 并扫码。"
        default:
            return gatewayError.localizedDescription
        }
    }

    // MARK: - Helpers

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.openClawRed)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 24)
    }

    private func testConnection() {
        connectionState = .testing

        Task {
            do {
                let baseURL = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
                    connectionState = .failed("Invalid gateway URL")
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")
                request.httpBody = Data("{\"model\":\"openclaw:main\",\"messages\":[],\"stream\":false}".utf8)
                request.timeoutInterval = 15

                let (_, response) = try await URLSession.shared.data(for: request)

                if let http = response as? HTTPURLResponse {
                    switch http.statusCode {
                    case 200...299, 400:
                        connectionState = .success
                    case 401, 403:
                        connectionState = .failed("Auth failed. Check your token.")
                    default:
                        connectionState = .failed("HTTP \(http.statusCode)")
                    }
                } else {
                    connectionState = .failed("Unexpected response")
                }
            } catch let error as URLError {
                switch error.code {
                case .notConnectedToInternet:
                    connectionState = .failed("No internet connection")
                case .timedOut:
                    connectionState = .failed("Timed out. Check URL and gateway.")
                case .cannotFindHost, .cannotConnectToHost:
                    connectionState = .failed("Cannot reach gateway.")
                case .secureConnectionFailed:
                    connectionState = .failed("SSL/TLS failed. Use HTTPS.")
                default:
                    connectionState = .failed(error.localizedDescription)
                }
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    private func finishOnboarding() {
        settingsStore.hasCompletedOnboarding = true
        settingsStore.save()
        onComplete()
    }
}

// MARK: - Gateway Setup Code

/// OpenClaw 网关配对码解析。
/// 配对码是 base64url 编码的 JSON：{"url":"wss://...","bootstrapToken":"..."}，
/// 由电脑端 `openclaw qr` 命令生成。兼容直接粘贴原始 JSON 的情况。
struct GatewaySetupCode: Codable, Equatable {
    let url: String
    let bootstrapToken: String

    /// 解析配对码（先试 base64url 解码，再试原始 JSON）。
    static func parse(_ raw: String) -> GatewaySetupCode? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = base64URLDecode(trimmed),
           let code = try? JSONDecoder().decode(GatewaySetupCode.self, from: data),
           isValid(code) {
            return code
        }

        if let data = trimmed.data(using: .utf8),
           let code = try? JSONDecoder().decode(GatewaySetupCode.self, from: data),
           isValid(code) {
            return code
        }

        return nil
    }

    /// 把配对码里的 ws(s):// 地址转成 http(s):// 网关地址（去掉路径，App 按配置拼接 /ws）。
    static func httpForm(of wsURL: String) -> String {
        let trimmed = wsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed
        }
        switch components.scheme?.lowercased() {
        case "wss":
            components.scheme = "https"
        case "ws":
            components.scheme = "http"
        default:
            break
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? trimmed
    }

    private static func isValid(_ code: GatewaySetupCode) -> Bool {
        !code.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !code.bootstrapToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func base64URLDecode(_ string: String) -> Data? {
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
