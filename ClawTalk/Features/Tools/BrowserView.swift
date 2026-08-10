import SwiftUI

struct BrowserView: View {
    @Bindable var viewModel: ToolsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                    if let screenshot = viewModel.browserScreenshot {
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
                        Task { await viewModel.takeBrowserScreenshot() }
                    }) {
                        Label("截取屏幕", systemImage: "camera")
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
