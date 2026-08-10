import SwiftUI

/// 日志与诊断：查看本地错误日志，复制，并同步到电脑端 OpenClaw 分析原因和解决方法。
struct DiagnosticsView: View {
    let settings: SettingsStore
    @State private var logs: [LogCollector.Entry] = []
    @State private var isSyncing = false
    @State private var resultText: String?
    @State private var syncError: String?

    private var logText: String {
        LogCollector.load()
            .reversed()
            .map { "[\($0.module)] \(Self.fmt($0.timestamp)) \($0.message)" }
            .joined(separator: "\n")
    }

    var body: some View {
        List {
            Section {
                Button {
                    syncToOpenClaw()
                } label: {
                    if isSyncing {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("正在同步…")
                        }
                    } else {
                        Label("同步到 OpenClaw", systemImage: "arrow.up.circle")
                    }
                }
                .disabled(isSyncing || settings.settings.gatewayURL.isEmpty)

                Button("复制全部") {
                    UIPasteboard.general.string = logText
                }
            } header: {
                Text("操作")
            } footer: {
                Text("把错误日志发送到电脑端 OpenClaw（会进入「日志诊断」频道），让它分析原因和给出解决方法，可回到该频道继续追问。")
            }

            if let resultText {
                Section("OpenClaw 分析") {
                    Text(resultText)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            if let syncError {
                Section {
                    Text(syncError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("最近日志") {
                if logs.isEmpty {
                    Text("暂无日志")
                        .foregroundStyle(.secondary)
                }
                ForEach(logs) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.module)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.openClawRed)
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("日志与诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            logs = LogCollector.load().reversed()
        }
    }

    private func syncToOpenClaw() {
        guard !settings.settings.gatewayURL.isEmpty else {
            syncError = "请先配置网关地址和令牌。"
            return
        }
        isSyncing = true
        syncError = nil
        resultText = nil
        InstructionChannels.ensureChannel(name: "日志诊断", systemEmoji: "🩺", sessionKey: InstructionChannels.diagnostics)
        let text = logText
        let instruction = "请分析以下 ClawTalk 客户端错误日志，逐条说明可能的原因和解决方法，用简体中文回复，最后给一个总结：\n\n" + text

        let gw = settings.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Task {
            do {
                let reply = try await OpenClawClient().chat(
                    messages: [Message(role: .user, content: instruction)],
                    gatewayURL: gw,
                    token: settings.gatewayToken,
                    sessionKey: InstructionChannels.diagnostics
                )
                isSyncing = false
                resultText = reply
            } catch {
                isSyncing = false
                syncError = "同步失败：\(AppErrorText.localized(error.localizedDescription))"
            }
        }
    }

    private static func fmt(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
