import SwiftUI

struct ToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ToolsViewModel
    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?
    private let nodeConnection: NodeConnection?

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil, nodeConnection: NodeConnection? = nil) {
        self.gatewayConnection = gatewayConnection
        self.settings = settings
        self.nodeConnection = nodeConnection
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

} header: {
                    Text("智能体工具")
                } footer: {
                    Text("直接调用智能体的工具，无需通过聊天。")
                }

                Section {
                    NavigationLink {
                        HomeCardManagerView()
                    } label: {
                        Label("主页卡片管理", systemImage: "square.grid.2x2")
                            .foregroundStyle(Color.openClawRed)
                    }
                } header: {
                    Text("主页")
                } footer: {
                    Text("管理主页显示的卡片：移除的卡片可在这里重新加回，也可在主页长按编辑。")
                }

                Section {
                    toolRow(.models, label: "模型", icon: "sparkles") {
                        ModelsView(viewModel: viewModel)
                    }

                    NavigationLink {
                        CapabilitiesView(settings: settings, nodeConnection: nodeConnection)
                    } label: {
                        Label("能力面板", systemImage: "square.stack.3d.up")
                            .foregroundStyle(Color.openClawRed)
                    }

                    NavigationLink {
                        CloneTalkView(settingsStore: settings)
                    } label: {
                        Label("AI 分身", systemImage: "person.crop.circle.badge.clock")
                            .foregroundStyle(Color.openClawRed)
                    }

                    NavigationLink {
                        CastPlayView()
                    } label: {
                        Label("投屏控制", systemImage: "airplayvideo")
                            .foregroundStyle(Color.openClawRed)
                    }

                    NavigationLink {
                        SettingsView(store: settings, gatewayConnection: gatewayConnection ?? GatewayConnection(), nodeConnection: nodeConnection)
                    } label: {
                        Label("主页外观", systemImage: "paintpalette")
                            .foregroundStyle(Color.openClawRed)
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

/// 主页卡片管理：开关主页显示的卡片（与 HomeCardRegistry 同一存储，双向同步）。
private struct HomeCardManagerView: View {
    @AppStorage(HomeCardRegistry.storageKey) private var storage = HomeCardRegistry.defaultStorageValue

    var body: some View {
        let enabled = HomeCardRegistry.enabledKinds(from: storage)
        List {
            Section {
                Text("主页卡片与本页实时同步。移除的卡片仍可在工具页找到并随时加回。")
            }
            ForEach(HomeCardKind.allCases) { kind in
                Button {
                    toggle(kind)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: kind.icon)
                            .font(.title3)
                            .foregroundStyle(kind.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .foregroundStyle(.primary)
                            Text(kind.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if enabled.contains(kind) {
                            Label("已在主页", systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.green)
                        } else {
                            Label("添加", systemImage: "plus.circle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("主页卡片管理")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ kind: HomeCardKind) {
        var kinds = HomeCardRegistry.enabledKinds(from: storage)
        if let index = kinds.firstIndex(of: kind) {
            kinds.remove(at: index)
        } else {
            kinds.append(kind)
        }
        HomeCardRegistry.setEnabledKinds(kinds)
        storage = HomeCardRegistry.storageValue(for: kinds)
    }
}