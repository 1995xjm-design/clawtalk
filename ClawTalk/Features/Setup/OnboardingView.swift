import SwiftUI
import UIKit

struct OnboardingView: View {
    @Bindable var settingsStore: SettingsStore
    let onComplete: () -> Void

    @State private var step: Step = .welcome
    @State private var gatewayURL = ""
    @State private var gatewayToken = ""
    @State private var connectionState: ConnectionTestState = .idle

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
        .preferredColorScheme(settingsStore.settings.appearance == .dark ? .dark : .light)
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
                .font(.system(size: 48))
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
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(.openClawRed)

            Text("连接网关")
                .font(.title2)
                .fontWeight(.bold)

            Text("填写你的 OpenClaw 网关地址和访问令牌。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // 首次连接引导：不会填就发给电脑 OpenClaw
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. 把下面这句话复制，发给电脑上的 OpenClaw：")
                    HStack(spacing: 8) {
                        Text("「请把网关连接地址和访问令牌完整发给我，令牌不要打码」")
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            UIPasteboard.general.string = "请把网关连接地址和访问令牌完整发给我，令牌不要打码"
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("2. 把 AI 回复的「地址」填到上面的「网关地址」，令牌填到下面的「访问令牌」。")
                    Text("3. 点「测试连接」，成功即可开始使用。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            } label: {
                Label("不知道怎么填？点这里看三步引导", systemImage: "questionmark.circle")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.openClawRed)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 16) {
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
                    Text("网关令牌")
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

            // Inline connection test result
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
                            .lineLimit(2)
                    case .idle:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 24)
                .transition(.opacity)
            }

            Spacer()

            primaryButton(connectionState == .success ? "继续" : "测试连接") {
                if connectionState == .success {
                    finishOnboarding()
                } else {
                    settingsStore.settings.gatewayURL = gatewayURL
                    settingsStore.gatewayToken = gatewayToken
                    settingsStore.save()
                    testConnection()
                }
            }
            .disabled(gatewayURL.isEmpty || gatewayToken.isEmpty || connectionState == .testing)
            .opacity(gatewayURL.isEmpty || gatewayToken.isEmpty ? 0.5 : 1)

            Button("跳过") {
                settingsStore.settings.gatewayURL = gatewayURL
                settingsStore.gatewayToken = gatewayToken
                settingsStore.save()
                finishOnboarding()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 60)
        }
        .animation(.easeInOut(duration: 0.2), value: connectionState)
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
