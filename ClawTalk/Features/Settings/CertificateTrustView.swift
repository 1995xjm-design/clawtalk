import SwiftUI

/// 证书信任设置页（任务 E）：查看/添加/删除已信任的自签证书网关主机。
struct CertificateTrustView: View {
    @State private var trustStore = CertificateTrustStore.shared
    @State private var newHost = ""

    var body: some View {
        List {
            Section {
                Label("信任自签证书的网关主机", systemImage: "lock.shield")
                Text("如果公网网关使用自签 HTTPS 证书，握手会被系统拦截。把网关的主机名加入信任名单后，连接会放行该主机的 TLS 校验。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    TextField("主机名或地址，如 124.156.180.143", text: $newHost)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit(addHost)
                    Button("添加") {
                        addHost()
                    }
                    .disabled(newHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("添加信任")
            }
            Section {
                if trustStore.trustedHosts.isEmpty {
                    Text("暂无已信任的主机。")
                        .foregroundStyle(.secondary)
                }
                ForEach(trustStore.trustedHosts, id: \.self) { host in
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text(host)
                            .font(.body.monospaced())
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        trustStore.untrust(trustStore.trustedHosts[index])
                    }
                }
            } header: {
                Text("已信任")
            } footer: {
                Text("仅当你确认网关证书来源可靠时才添加信任；信任后该主机将跳过证书链校验。证书信任名单仅保存在本机。")
            }
        }
        .navigationTitle("证书信任")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addHost() {
        let input = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if let host = CertificateTrustStore.host(from: input) {
            trustStore.trust(host)
        } else {
            trustStore.trust(input)
        }
        newHost = ""
    }
}