import SwiftUI

struct ToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ToolsViewModel
    private let settings: SettingsStore

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil) {
        self.settings = settings
        _viewModel = State(initialValue: ToolsViewModel(settings: settings, gatewayConnection: gatewayConnection))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    toolRow(.memory, label: "记忆", icon: "brain.head.profile") {
                        MemorySearchView(viewModel: viewModel)
                    }

                    toolRow(.agents, label: "智能体", icon: "cpu") {
                        AgentsView(viewModel: viewModel)
                    }

                    toolRow(.sessions, label: "会话", icon: "list.bullet.rectangle") {
                        SessionsView(viewModel: viewModel)
                    }

                    toolRow(.browser, label: "浏览器", icon: "globe") {
                        BrowserView(viewModel: viewModel)
                    }

                    NavigationLink {
                        FileTransferChannelView(settings: settings, embeddedInNavigation: true)
                    } label: {
                        Label("文件传输助手", systemImage: "paperplane")
                            .foregroundStyle(.openClawRed)
                    }

} header: {
                    Text("智能体工具")
                } footer: {
                    Text("直接调用智能体的工具，无需通过聊天。")
                }

                Section {
                    toolRow(.models, label: "模型", icon: "sparkles") {
                        ModelsView(viewModel: viewModel)
                    }
                } header: {
                    Text("网关信息")
                } footer: {
                    if !viewModel.isAvailable(.models) {
                        Text("在设置中开启 WebSocket 模式后可浏览可用模型。")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task {
                await viewModel.checkAvailability()
            }
        }
    }

    @ViewBuilder
    private func toolRow<Destination: View>(
        _ category: ToolsViewModel.ToolCategory,
        label: String,
        icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        let available = viewModel.isAvailable(category)

        if available {
            NavigationLink {
                destination()
            } label: {
                Label(label, systemImage: icon)
                    .foregroundStyle(Color.openClawRed)
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    Text(category == .models ? "需要 WebSocket 连接" : "网关未启用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon)
            }
            .foregroundStyle(.secondary)
        }
    }
}
