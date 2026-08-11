import SwiftUI

struct ModelsView: View {
    @Bindable var viewModel: ToolsViewModel

    /// 网关配置快照（只读，用于展示网关地址；实际请求仍走 viewModel）
    private let settingsSnapshot = SettingsStore()

    /// 测试连接状态
    enum ConnectionState: Equatable {
        case idle
        case testing
        case success(latencyMs: Int, modelCount: Int)
        case failed(String)
    }

    @State private var connectionState: ConnectionState = .idle

    /// 本地参考清单：网关未返回模型时的兜底展示（诚实标注「本地参考」）
    private let localFallbackModels: [ModelEntry] = [
        ModelEntry(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", provider: "Anthropic", contextWindow: 200_000, reasoning: true),
        ModelEntry(id: "claude-opus-4-1", name: "Claude Opus 4.1", provider: "Anthropic", contextWindow: 200_000, reasoning: true),
        ModelEntry(id: "gpt-4o", name: "GPT-4o", provider: "OpenAI", contextWindow: 128_000, reasoning: false),
        ModelEntry(id: "gpt-4.1-mini", name: "GPT-4.1 mini", provider: "OpenAI", contextWindow: 1_000_000, reasoning: false),
        ModelEntry(id: "deepseek-chat", name: "DeepSeek V3", provider: "DeepSeek", contextWindow: 64_000, reasoning: false),
        ModelEntry(id: "deepseek-reasoner", name: "DeepSeek R1", provider: "DeepSeek", contextWindow: 64_000, reasoning: true)
    ]

    private var defaultChannel: Channel? {
        ChannelStore.shared.channels.first
    }

    var body: some View {
        List {
            connectionSection
            currentUsageSection
            modelsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 首次进入：加载模型并顺带完成一次「测试连接」
            if viewModel.availableModels.isEmpty && connectionState == .idle {
                await testConnection()
            }
        }
    }

    // MARK: - 网关连接

    private var connectionSection: some View {
        Section {
            LabeledContent("网关地址", value: gatewayAddress)

            LabeledContent("连接状态", value: connectionStatusText)

            LabeledContent("延迟", value: latencyText)

            Button {
                Task { await testConnection() }
            } label: {
                if connectionState == .testing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在测试连接...")
                    }
                } else {
                    Label("测试连接", systemImage: "bolt.horizontal.circle")
                }
            }
            .disabled(connectionState == .testing)
            .foregroundStyle(Color.openClawRed)
        } header: {
            Text("网关连接")
        } footer: {
            Text("测试会向网关发送最小模型列表请求并计时，用于确认连通性与延迟。")
        }
    }

    private var gatewayAddress: String {
        let raw = settingsSnapshot.settings.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "未配置（请到设置页配置）" : raw
    }

    private var connectionStatusText: String {
        switch connectionState {
        case .idle:
            return viewModel.availableModels.isEmpty ? "未检测" : "网关可用"
        case .testing:
            return "检测中..."
        case .success:
            return "连接正常"
        case .failed:
            return "连接失败"
        }
    }

    private var latencyText: String {
        if case .success(let latencyMs, _) = connectionState {
            return "\(latencyMs) ms"
        }
        return "-"
    }

    // MARK: - 当前使用

    private var currentUsageSection: some View {
        Section {
            if let channel = defaultChannel {
                LabeledContent("默认频道", value: channel.name)
                LabeledContent("路由方式", value: "openclaw:\(channel.agentId)")
                if let model = channel.selectedModel, !model.isEmpty {
                    LabeledContent("频道指定模型", value: model)
                } else {
                    LabeledContent("频道指定模型", value: "跟随网关默认")
                }
            } else {
                Text("暂无频道")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("当前使用")
        } footer: {
            Text("ClawTalk 采用智能体路由（openclaw:<agentId>），实际模型由网关与各频道决定。")
        }
    }

    // MARK: - 可用模型

    @ViewBuilder
    private var modelsSection: some View {
        if viewModel.isLoadingModels && viewModel.availableModels.isEmpty {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在加载模型...")
                        .foregroundStyle(.secondary)
                }
            }
        } else if let error = viewModel.errorMessage, viewModel.availableModels.isEmpty {
            Section {
                Label("模型加载失败", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    Task { await viewModel.loadModels() }
                }
            } header: {
                Text("可用模型")
            }
        } else if viewModel.availableModels.isEmpty {
            Section {
                Label("未连接网关", systemImage: "wifi.slash")
                Text("网关未返回模型。下方为本地参考清单，不代表网关当前可用模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(localFallbackModels) { model in
                    modelRow(model)
                }
            } header: {
                Text("本地参考清单")
            }
        } else {
            Section {
                Text("网关返回 \(viewModel.availableModels.count) 个可用模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(groupedProviders, id: \.provider) { group in
                Section(group.provider) {
                    ForEach(group.models) { model in
                        modelRow(model)
                    }
                }
            }
        }
    }

    private func modelRow(_ model: ModelEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.displayName)
                .font(.body)
                .fontWeight(.medium)

            HStack(spacing: 12) {
                if let provider = model.provider, !provider.isEmpty {
                    Label(provider, systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let contextWindow = model.contextWindow {
                    Label(formatTokenCount(contextWindow), systemImage: "text.word.spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.reasoning == true {
                    Label("推理", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.openClawRed)
                }
            }

            Text(model.id)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 测试连接

    @MainActor
    private func testConnection() async {
        connectionState = .testing
        let start = Date()
        await viewModel.loadModels()
        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
        if viewModel.availableModels.isEmpty, let error = viewModel.errorMessage {
            connectionState = .failed(error)
        } else {
            connectionState = .success(latencyMs: latencyMs, modelCount: viewModel.availableModels.count)
        }
    }

    private struct ProviderGroup {
        let provider: String
        let models: [ModelEntry]
    }

    private var groupedProviders: [ProviderGroup] {
        let grouped = Dictionary(grouping: viewModel.availableModels) { $0.provider ?? "其他" }
        return grouped.keys.sorted().map { ProviderGroup(provider: $0, models: grouped[$0]!) }
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000 {
            return "\(count / 1_000)k 上下文"
        }
        return "\(count) 上下文"
    }
}
