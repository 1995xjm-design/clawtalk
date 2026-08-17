import SwiftUI
import UIKit

/// 官方 6 步引导页：intro → welcome → mode → connect → auth → success。
/// 内容 100% 对齐官方 OpenClaw iOS 引导页（6 页），UI 用 ClawTalk 主题、文案全中文。
struct OnboardingView: View {
    @Bindable var settingsStore: SettingsStore
    let onComplete: () -> Void

    @State private var step: Step = .intro
    @State private var gatewayURL = ""
    @State private var gatewayToken = ""
    @State private var gatewayPassword = ""
    @State private var gatewayHost = ""
    @State private var gatewayPort = "18789"
    @State private var useTLS = true
    @State private var selectedMode: GatewayMode = .lan
    @State private var setupCodeInput = ""
    @State private var devMode = false
    @State private var connectionState: ConnectionTestState = .idle
    @State private var showScanner = false
    @State private var scanNotice: String?
    @State private var rescanToken = 0
    @State private var copiedCommand = false
    @State private var needsApproval = false

    enum Step: Int, CaseIterable {
        case intro = 0
        case welcome
        case mode
        case connect
        case auth
        case success
    }

    enum GatewayMode: String, CaseIterable, Identifiable {
        case lan
        case remote
        case local

        var id: String { rawValue }

        var title: String {
            switch self {
            case .lan: return "家庭网络"
            case .remote: return "远程域名"
            case .local: return "本机开发"
            }
        }

        var subtitle: String {
            switch self {
            case .lan: return "本机局域网自动发现网关"
            case .remote: return "通过域名 + Token 连接"
            case .local: return "同一台电脑上调试"
            }
        }

        var symbol: String {
            switch self {
            case .lan: return "wifi"
            case .remote: return "globe"
            case .local: return "laptopcomputer"
            }
        }
    }

    enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failed(String)
    }

    var body: some View {
        TabView(selection: $step) {
            introStep.tag(Step.intro)
            welcomeStep.tag(Step.welcome)
            modeStep.tag(Step.mode)
            connectStep.tag(Step.connect)
            authStep.tag(Step.auth)
            successStep.tag(Step.success)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .onAppear {
            UIPageControl.appearance().currentPageIndicatorTintColor = UIColor(.openClawRed)
            UIPageControl.appearance().pageIndicatorTintColor = UIColor(.openClawRed).withAlphaComponent(0.3)
            UserDefaults.standard.set(true, forKey: "onboarding.first_run_intro_seen")
        }
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
        .background(Color(.systemBackground))
        .preferredColorScheme(settingsStore.settings.preferredColorScheme)
    }

    // MARK: - P1 Intro（欢迎页，全屏无导航）

    private var introStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("LogoRed")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)

            Text("ClawTalk")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 6)

            Text("你的智能体，装进口袋。\n把这部 iPhone 和你的网关配对即可开始。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(symbol: "desktopcomputer", title: "智能体运行在你自己的电脑上")
                featureRow(symbol: "qrcode.viewfinder", title: "扫描设置码即可配对这台 iPhone")
                featureRow(symbol: "message.fill", title: "随时随地聊天、语音、批准操作")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)

            securityNotice
                .padding(.horizontal, 24)
                .padding(.top, 12)

            Spacer()

            primaryButton("继续") {
                withAnimation { step = .welcome }
            }

            Button("跳过") {
                finishOnboarding()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 40)
        }
    }

    // MARK: - P2 Welcome（连接网关）

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "qrcode.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(.openClawRed)

            Text("连接网关")
                .font(.title2)
                .fontWeight(.bold)

            Text("在网关主机上运行以下命令，然后扫描二维码")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            qrCommandBox
                .padding(.horizontal, 24)

            primaryButton("扫码连接") {
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
                    withAnimation { step = .mode }
                } label: {
                    Label("手动连接", systemImage: "slider.horizontal.3")
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

            connectionStatusRow
                .padding(.horizontal, 24)

            Spacer()

            Button("跳过") {
                finishOnboarding()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 40)
        }
        .animation(.easeInOut(duration: 0.2), value: connectionState)
    }

    // MARK: - P3 Mode（网关设置表单）

    private var modeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.openClawRed)

            Text("网关设置")
                .font(.title2)
                .fontWeight(.bold)

            Text("输入设置码可直达连接；或选择连接模式后继续。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 6) {
                Text("设置码")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    TextField("输入设置码", text: $setupCodeInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(12)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button("连接") {
                        connectWithSetupCode(setupCodeInput)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.openClawRed)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(setupCodeInput.isEmpty)
                    .opacity(setupCodeInput.isEmpty ? 0.5 : 1)
                }
            }
            .padding(.horizontal, 24)

            VStack(spacing: 10) {
                ForEach(GatewayMode.allCases) { mode in
                    modeCard(mode)
                }
            }
            .padding(.horizontal, 24)

            Toggle("开发者模式", isOn: $devMode)
                .font(.subheadline)
                .padding(.horizontal, 24)

            Spacer()

            primaryButton("下一步") {
                withAnimation { step = .connect }
            }

            Button("返回") {
                withAnimation { step = .welcome }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
        }
    }

    private func modeCard(_ mode: GatewayMode) -> some View {
        Button {
            selectedMode = mode
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selectedMode == mode ? .white : Color.openClawRed)
                    .frame(width: 34, height: 34)
                    .background {
                        Circle().fill(selectedMode == mode ? Color.openClawRed : Color.openClawRed.opacity(0.12))
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(mode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selectedMode == mode {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.openClawRed)
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selectedMode == mode ? Color.openClawRed : Color.secondary.opacity(0.2), lineWidth: selectedMode == mode ? 1.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - P4 Connect（网关详情表单）

    private var connectStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "network")
                .font(.largeTitle)
                .foregroundStyle(.openClawRed)

            Text("网关详情")
                .font(.title2)
                .fontWeight(.bold)

            connectionStatusRow
                .padding(.horizontal, 24)

            if selectedMode == .remote {
                labeledField("域名", text: $gatewayURL, keyboard: .URL)
                    .padding(.horizontal, 24)
            } else {
                labeledField("主机", text: $gatewayHost, keyboard: .URL)
                    .padding(.horizontal, 24)
            }

            labeledField("端口", text: $gatewayPort, keyboard: .numberPad)
                .padding(.horizontal, 24)

            Toggle("启用 TLS", isOn: $useTLS)
                .font(.subheadline)
                .padding(.horizontal, 24)

            primaryButton("测试连接") {
                saveManualGateway()
                testWebSocketWithManualCredentials()
            }
            .disabled(connectFieldsInvalid)
            .opacity(connectFieldsInvalid ? 0.5 : 1)

            Button("返回") {
                withAnimation { step = .mode }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
        }
    }

    private var connectFieldsInvalid: Bool {
        if selectedMode == .remote {
            return gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - P5 Auth（认证 + 配对批准表单）

    private var authStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(.openClawRed)

            Text("认证")
                .font(.title2)
                .fontWeight(.bold)

            labeledField("网关认证令牌", text: $gatewayToken, secure: true)
                .padding(.horizontal, 24)

            labeledField("网关密码", text: $gatewayPassword, secure: true)
                .padding(.horizontal, 24)

            connectionStatusRow
                .padding(.horizontal, 24)

            if needsApproval {
                approvalBox
                    .padding(.horizontal, 24)
            }

            VStack(spacing: 10) {
                primaryButton("批准后继续") {
                    retryConnection()
                }
                .disabled(gatewayToken.isEmpty && gatewayPassword.isEmpty)
                .opacity(gatewayToken.isEmpty && gatewayPassword.isEmpty ? 0.5 : 1)

                HStack(spacing: 24) {
                    Button("重新扫码") {
                        scanNotice = nil
                        showScanner = true
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.openClawRed)

                    Button("重试连接") {
                        retryConnection()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.openClawRed)
                }
            }

            Button("返回") {
                withAnimation { step = .connect }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
        }
    }

    /// 配对批准引导（对齐官方：在网关批准这台设备）。
    private var approvalBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("需要网关批准这台设备", systemImage: "clock.badge.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text("在网关主机上运行以下命令批准配对：")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("openclaw devices approve")
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = "openclaw devices approve"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
            .padding(10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("或在 OpenClaw 聊天里发送 /pair approve。返回本 App 会自动重试。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        }
    }

    // MARK: - P6 Success（完成页，全屏无导航）

    private var successStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 84))
                .foregroundStyle(.green)

            Text("已连接")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 18)

            Text(gatewayDisplayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 32)

            Spacer()

            primaryButton("前往聊天") {
                finishOnboarding()
            }
            .padding(.bottom, 40)
        }
    }

    private var gatewayDisplayName: String {
        let base = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty { return base }
        return settingsStore.settings.gatewayURL
    }

    // MARK: - Shared UI

    private func featureRow(symbol: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.openClawRed)
                .frame(width: 34, height: 34)
                .background {
                    Circle().fill(Color.openClawRed.opacity(0.12))
                }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var securityNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("安全提示")
                    .font(.headline)
                Text("连接的智能体可以使用你开启的设备能力。相机、麦克风、相册、通讯录、日历和位置可能被调用。仅在你信任所连接的网关和智能体时继续。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        }
    }

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

    private func labeledField(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            if secure {
                SecureField(title, text: text)
                    .textContentType(.password)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                TextField(title, text: text)
                    .keyboardType(keyboard)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

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

    // MARK: - Connection Flow

    private func handleScannedCode(_ raw: String) {
        guard let link = GatewayConnectDeepLink.fromSetupInput(raw) else {
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
        connectWithSetupCode(raw)
    }

    private func connectWithSetupCode(_ raw: String) {
        guard let link = GatewayConnectDeepLink.fromSetupInput(raw) else {
            connectionState = .failed("无法识别配对码")
            return
        }
        applySetupCode(link)
    }

    private func applySetupCode(_ link: GatewayConnectDeepLink) {
        gatewayURL = link.httpGatewayURL
        settingsStore.applyGatewayDeepLink(link)
        connectionState = .testing
        needsApproval = false

        Task { @MainActor in
            await testWebSocketConnection(
                token: link.token,
                bootstrapToken: link.bootstrapToken,
                password: link.password
            )
        }
    }

    /// 手动模式：把表单字段写入设置并保存令牌/密码。
    private func saveManualGateway() {
        let built = buildGatewayURLFromFields()
        if !built.isEmpty {
            settingsStore.settings.gatewayURL = built
        }
        let port = gatewayPort.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.settings.webSocketPath = port.isEmpty ? "18789" : port
        if !gatewayToken.isEmpty {
            settingsStore.gatewayToken = gatewayToken
        }
        settingsStore.save()
    }

    private func buildGatewayURLFromFields() -> String {
        if selectedMode == .remote {
            return gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let host = gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = gatewayPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = useTLS ? "https" : "http"
        if host.isEmpty { return "" }
        if port.isEmpty { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    private func testWebSocketWithManualCredentials() {
        connectionState = .testing
        needsApproval = false
        Task { @MainActor in
            await testWebSocketConnection(
                token: gatewayToken.isEmpty ? nil : gatewayToken,
                bootstrapToken: nil,
                password: gatewayPassword.isEmpty ? nil : gatewayPassword
            )
        }
    }

    private func retryConnection() {
        connectionState = .testing
        Task { @MainActor in
            await testWebSocketConnection(
                token: gatewayToken.isEmpty ? nil : gatewayToken,
                bootstrapToken: settingsStore.settings.bootstrapToken,
                password: gatewayPassword.isEmpty ? nil : gatewayPassword
            )
        }
    }

    /// 用 WebSocket 握手配对（配对成功即视为连接成功）。
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
            UserDefaults.standard.set(true, forKey: "gateway.hasConnectedOnce")
            withAnimation { step = .success }
        } catch {
            await gateway.shutdown()
            if let gatewayError = error as? GatewayWebSocket.GatewayError,
               case .pairingRequired = gatewayError {
                needsApproval = true
                connectionState = .failed("等待网关批准这台设备")
                withAnimation { step = .auth }
            } else {
                connectionState = .failed(pairingErrorMessage(for: error))
            }
        }
    }

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

    private func finishOnboarding() {
        settingsStore.hasCompletedOnboarding = true
        settingsStore.save()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "onboarding.completed")
        defaults.set(true, forKey: "gateway.onboardingComplete")
        defaults.set(selectedMode.rawValue, forKey: "onboarding.last_mode")
        defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: "onboarding.last_success_time")
        onComplete()
    }
}

// MARK: - Gateway Setup Code

/// OpenClaw 网关配对码解析。
struct GatewaySetupCode: Codable, Equatable {
    let url: String
    let bootstrapToken: String

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