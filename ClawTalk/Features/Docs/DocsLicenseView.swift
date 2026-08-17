import SwiftUI

/// 文档与许可（OpenClawDocsScreen + LicenseDocuments 精简版）。
struct DocsLicenseView: View {
    var body: some View {
        List {
            Section("官方文档") {
                Link(destination: URL(string: "https://docs.openclaw.ai")!) {
                    Label("OpenClaw 文档", systemImage: "book.fill")
                }
                Link(destination: URL(string: "https://docs.openclaw.ai/gateway")!) {
                    Label("网关指南", systemImage: "server.rack")
                }
            }
            Section("许可证") {
                licenseRow("ClawTalk", "本应用基于 OpenClaw 项目构建。")
                licenseRow("Rime / 输入法方案", "Rime 引擎与方案遵循各自开源许可证。")
                licenseRow("第三方依赖", "详见项目 LICENSE 文件。")
            }
            Section("版本") {
                HStack {
                    Text("应用版本")
                    Spacer()
                    Text(appVersion)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("构建号")
                    Spacer()
                    Text(buildNumber)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("文档与许可")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenseRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}