import SwiftUI

/// 快速设置网关（GatewayQuickSetupSheet 精简版）：Bonjour 发现候选网关 + 手动设置入口。
struct GatewayQuickSetupSheet: View {
    let knownGatewayURL: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var discoveryModel = GatewayDiscoveryModel()
    @State private var manualURL = ""

    var body: some View {
        NavigationStack {
            List {
                Section("发现网关") {
                    if discoveryModel.gateways.isEmpty {
                        Text(discoveryModel.statusText.isEmpty ? "未发现网关" : discoveryModel.statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(discoveryModel.gateways) { gateway in
                        Button {
                            onPick(httpURL(of: gateway))
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .foregroundStyle(.openClawRed)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(gateway.name)
                                        .font(.subheadline.weight(.medium))
                                    Text(displayHost(gateway))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let port = gateway.gatewayPort {
                                    Text("\(port)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("手动设置") {
                    TextField("https://host:port", text: $manualURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("使用此地址") {
                        let trimmed = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onPick(trimmed)
                        dismiss()
                    }
                    .disabled(manualURL.isEmpty)
                }
            }
            .navigationTitle("快速设置网关")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onAppear {
            discoveryModel.start()
        }
        .onDisappear {
            discoveryModel.stop()
        }
    }

    private func displayHost(_ gateway: GatewayDiscoveryModel.DiscoveredGateway) -> String {
        gateway.lanHost ?? gateway.tailnetDns ?? "未知主机"
    }

    private func httpURL(of gateway: GatewayDiscoveryModel.DiscoveredGateway) -> String {
        let host = displayHost(gateway)
        let port = gateway.gatewayPort ?? 18789
        let scheme = gateway.tlsEnabled ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
    }
}