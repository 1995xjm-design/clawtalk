import SwiftUI

/// 远程终端（任务 H）：输入命令 -> 通过网关 chat 让 OpenClaw agent 执行 -> 流式显示输出。
/// 输出方式：网关未提供交互式 WS 终端会话，本页通过 OpenClawClient.stream（SSE 流式回显）
/// 持续显示命令输出；流式中断时保留已回显部分并诚实标注错误。
/// 入口已加在设置页「系统集成」分组；也可由主智能体在工具页/ToolsView 增加入口。
struct TerminalView: View {
    @Bindable var store: SettingsStore

    /// 终端专用会话 key（与电脑端 OpenClaw 的固定会话，可追溯）
    private static let terminalSessionKey = "agent:main:clawtalk-user:terminal"

    struct TerminalEntry: Identifiable {
        let id = UUID()
        let command: String
        var output: String
        let date: Date
        let isError: Bool
        var isStreaming: Bool
    }

    @State private var entries: [TerminalEntry] = []
    @State private var command = ""
    @State private var isRunning = false
    @State private var errorMessage: String?
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            if entries.isEmpty {
                ContentUnavailableView(
                    "远程终端",
                    systemImage: "terminal",
                    description: Text("输入命令，由网关上的 OpenClaw agent 执行并流式返回真实输出。\n网关未提供交互式 WS 终端，本页为「命令执行 + SSE 流式回显」，同一会话可持续输入。")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(entries) { entry in
                                TerminalEntryView(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: entries.count) { _, _ in
                        if let last = entries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("输入命令，如 ls -la", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.send)
                    .focused($commandFocused)
                    .onSubmit(run)
                    .disabled(isRunning)
                Button {
                    run()
                } label: {
                    if isRunning {
                        ProgressView()
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
        .navigationTitle("远程终端")
        .navigationBarTitleDisplayMode(.inline)
        .alert("命令执行失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 连接状态

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        if !store.isConfigured { return .orange }
        if isRunning { return .green }
        if entries.last?.isError == true { return .red }
        return .secondary
    }

    private var statusText: String {
        if !store.isConfigured { return "未配置网关" }
        if isRunning { return "执行中 · SSE 流式回显（网关会话）" }
        if entries.last?.isError == true { return "上次执行失败，已保留已回显输出" }
        return "就绪 · 网关会话 · 非交互式终端"
    }

    // MARK: - 执行

    private func run() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard store.isConfigured else {
            errorMessage = "尚未配置网关，请先在设置中填写网关地址与令牌。"
            return
        }

        isRunning = true
        commandFocused = false
        let baseURL = store.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let token = store.gatewayToken
        let instruction = "请执行以下命令，并返回命令的真实输出（stdout/stderr）。如果命令需要确认或会修改系统，请直接说明而不执行。\n命令：\(trimmed)"

        let entry = TerminalEntry(command: trimmed, output: "", date: Date(), isError: false, isStreaming: true)
        entries.append(entry)

        Task {
            do {
                let stream = OpenClawClient().stream(
                    messages: [Message(role: .user, content: instruction)],
                    gatewayURL: baseURL,
                    token: token,
                    model: "openclaw:main",
                    apiMode: store.settings.agentAPIMode,
                    sessionKey: Self.terminalSessionKey
                )
                var output = ""
                for try await event in stream {
                    switch event {
                    case .textDelta(let delta):
                        output += delta
                        if let index = entries.lastIndex(where: { $0.id == entry.id }) {
                            entries[index].output = output
                        }
                    case .modelIdentified:
                        break
                    case .completed:
                        break
                    }
                }
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output = "（无输出）"
                }
                finalize(entry, output: output, isError: false)
                command = ""
            } catch {
                let message = "执行失败：\(AppErrorText.localized(error.localizedDescription))"
                if let index = entries.lastIndex(where: { $0.id == entry.id }) {
                    let partial = entries[index].output
                    let combined = partial.isEmpty ? message : partial + "\n\n" + message
                    finalize(entry, output: combined, isError: true)
                }
                errorMessage = message
                LogCollector.record(module: "远程终端", message)
            }
            isRunning = false
        }
    }

    private func finalize(_ entry: TerminalEntry, output: String, isError: Bool) {
        guard let index = entries.lastIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = TerminalEntry(
            command: entry.command,
            output: output,
            date: entry.date,
            isError: isError,
            isStreaming: false
        )
    }
}

/// 单条命令/输出展示。
private struct TerminalEntryView: View {
    let entry: TerminalView.TerminalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("$ \(entry.command)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                if entry.isStreaming {
                    Label("流式输出中", systemImage: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(entry.output.isEmpty ? "（无输出）" : entry.output)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.isError ? .red : .secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}