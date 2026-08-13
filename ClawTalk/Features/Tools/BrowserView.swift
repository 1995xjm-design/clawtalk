import SwiftUI

struct BrowserView: View {
    @Bindable var viewModel: ToolsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !viewModel.browserToolAvailable {
                    VStack(spacing: 10) {
                        Label("电脑端未配置浏览器工具", systemImage: "wrench.and.screwdriver")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("状态、截图、标签页都需要电脑端 OpenClaw 安装浏览器工具。点下方按钮自动安装。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await viewModel.installBrowserTool() }
                        } label: {
                            if viewModel.isInstallingBrowserTool {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("一键安装", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.openClawRed)
                        .disabled(viewModel.isInstallingBrowserTool)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Status section
                Section {
                    if let status = viewModel.browserStatusText {
                        JSONPrettyView(jsonString: status)
                    }

                    Button(action: {
                        Task { await viewModel.getBrowserStatus() }
                    }) {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } header: {
                    Label("状态", systemImage: "info.circle")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }

                Divider()

                // Screenshot section
                Section {
                    if let screenshot = viewModel.desktopScreenshot {
                        Image(uiImage: screenshot)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color(.systemGray4), lineWidth: 1)
                            )
                    }

                    Button(action: {
                        Task { await viewModel.takeDesktopScreenshot() }
                    }) {
                        Label("截取电脑屏幕", systemImage: "display")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.openClawRed)
                } header: {
                    Label("截图", systemImage: "camera.viewfinder")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }

                Divider()

                // Tabs section
                Section {
                    if let tabs = viewModel.browserTabsText {
                        JSONPrettyView(jsonString: Self.extractJSON(from: tabs))
                    }

                    Button(action: {
                        Task { await viewModel.getBrowserTabs() }
                    }) {
                        Label("列出标签页", systemImage: "square.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } header: {
                    Label("标签页", systemImage: "square.on.square")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }
            .padding()
        }
        .navigationTitle("浏览器")
        .overlay {
            if viewModel.isLoading {
                ProgressView()
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .task {
            await viewModel.checkBrowserTool()
            await viewModel.getBrowserStatus()
        }
    }

    /// Strip `<<<EXTERNAL_UNTRUSTED_CONTENT>>>` wrapper and `Source: ...\n---` header
    /// to extract the raw JSON from gateway tool responses.
    private static func extractJSON(from text: String) -> String {
        var cleaned = text

        // Remove <<<EXTERNAL_UNTRUSTED_CONTENT id="...">>>>
        if let startRange = cleaned.range(of: ">>>>\n") {
            cleaned = String(cleaned[startRange.upperBound...])
        }
        // Remove <<<END_EXTERNAL_UNTRUSTED_CONTENT id="...">>>>
        if let endRange = cleaned.range(of: "\n<<<END_EXTERNAL_UNTRUSTED_CONTENT") {
            cleaned = String(cleaned[..<endRange.lowerBound])
        }
        // Remove "Source: ...\n---\n"
        if let dashRange = cleaned.range(of: "---\n") {
            cleaned = String(cleaned[dashRange.upperBound...])
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
