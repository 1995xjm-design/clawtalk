import SwiftUI

struct AddChannelView: View {
    var channelStore: ChannelStore
    var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var agentId = ""
    @State private var customAgentId = ""
    @State private var agents: [AgentEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private let client = OpenClawClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("频道名称", text: $name)
                } header: {
                    Text("名称")
                }

                if !agents.isEmpty {
                    Section {
                        ForEach(agents) { agent in
                            Button(action: {
                                agentId = agent.agentId
                                customAgentId = ""
                                if name.isEmpty {
                                    name = agent.agentId.capitalized
                                }
                            }) {
                                HStack {
                                    Text(agent.agentId)
                                        .font(.body)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    if agentId == agent.agentId && customAgentId.isEmpty {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.openClawRed)
                                            .fontWeight(.semibold)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    } header: {
                        Text("智能体")
                    }
                }

                Section {
                    if isLoading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("正在加载智能体…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextField("智能体 ID", text: $customAgentId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: customAgentId) {
                            if !customAgentId.isEmpty {
                                agentId = customAgentId
                            }
                        }

                    if let error = loadError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(agents.isEmpty ? "智能体" : "或手动输入")
                } footer: {
                    Text("输入上方未显示的智能体 ID，或使用 \"main\" 作为默认智能体。")
                }
            }
            .navigationTitle("新建频道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let channel = Channel(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            agentId: agentId.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        channelStore.add(channel)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              agentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                await loadAgents()
            }
        }
    }

    private func loadAgents() async {
        guard settings.isConfigured else {
            loadError = "请先在设置中配置网关。"
            return
        }

        isLoading = true
        do {
            let data = try await client.invokeTool(
                tool: "agents_list",
                gatewayURL: settings.settings.gatewayURL,
                token: settings.gatewayToken
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<AgentsListResult>.self, from: data)
            agents = wrapper.details?.agents ?? []
        } catch {
            loadError = "无法加载智能体列表。"
        }
        isLoading = false
    }
}
