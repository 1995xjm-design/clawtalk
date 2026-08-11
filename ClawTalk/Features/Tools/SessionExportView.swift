import Foundation
import SwiftUI

// MARK: - 导出来源

/// 导出来源：本地频道（ConversationStore 消息）或网关会话（sessions_history）。
enum SessionExportSource: Identifiable {
    case channel(Channel)
    case gatewaySession(SessionEntry, title: String)

    var id: String {
        switch self {
        case .channel(let channel):
            return "channel-\(channel.id.uuidString)"
        case .gatewaySession(let session, _):
            return "session-\(session.key)"
        }
    }

    var displayTitle: String {
        switch self {
        case .channel(let channel):
            return channel.name
        case .gatewaySession(_, let title):
            return title
        }
    }
}

// MARK: - 导出格式

enum SessionExportFormat: String, CaseIterable, Identifiable {
    case text = "文本"
    case markdown = "Markdown"
    case json = "JSON"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .json: return "json"
        }
    }
}

// MARK: - 导出行（统一本地频道与网关会话两种来源）

struct SessionExportMessage {
    let role: String
    let content: String
    let timestamp: Date?
    let model: String?
}

struct SessionExportData {
    let title: String
    let messages: [SessionExportMessage]
    let exportedAt: Date
}

enum SessionExportError: LocalizedError {
    case emptyHistory
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyHistory:
            return "网关未返回会话历史"
        case .loadFailed(let message):
            return message
        }
    }
}

// MARK: - 导出内容构建

enum SessionExportBuilder {

    static func content(for format: SessionExportFormat, export data: SessionExportData) -> String {
        switch format {
        case .text:
            return text(export: data)
        case .markdown:
            return markdown(export: data)
        case .json:
            return json(export: data)
        }
    }

    static func text(export data: SessionExportData) -> String {
        var lines: [String] = []
        lines.append("「\(data.title)」会话导出")
        lines.append("导出时间：\(formatDate(data.exportedAt))")
        lines.append("消息数：\(data.messages.count)")
        lines.append("")
        for message in data.messages {
            lines.append("")
            let timestamp = message.timestamp.map { formatDate($0) } ?? ""
            lines.append("【\(roleName(message.role))】\(timestamp)")
            if let model = message.model, !model.isEmpty {
                lines.append("模型：\(model)")
            }
            lines.append(message.content)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func markdown(export data: SessionExportData) -> String {
        var lines: [String] = []
        lines.append("# \(data.title)")
        lines.append("")
        lines.append("> 导出时间：\(formatDate(data.exportedAt)) · 共 \(data.messages.count) 条")
        lines.append("")
        for message in data.messages {
            lines.append("## \(roleName(message.role))")
            if let timestamp = message.timestamp {
                lines.append("*\(formatDate(timestamp))*")
            }
            if let model = message.model, !model.isEmpty {
                lines.append("模型：`\(model)`")
            }
            lines.append("")
            lines.append(message.content.replacingOccurrences(of: "\n", with: "\n\n"))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func json(export data: SessionExportData) -> String {
        struct ExportEnvelope: Codable {
            let title: String
            let exportedAt: Date
            let messageCount: Int
            let messages: [ExportJSONMessage]
        }

        struct ExportJSONMessage: Codable {
            let role: String
            let content: String
            let timestamp: String?
            let model: String?
        }

        let envelope = ExportEnvelope(
            title: data.title,
            exportedAt: data.exportedAt,
            messageCount: data.messages.count,
            messages: data.messages.map { message in
                ExportJSONMessage(
                    role: message.role,
                    content: message.content,
                    timestamp: message.timestamp.map { formatDate($0) },
                    model: message.model
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(envelope),
              let text = String(data: encoded, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 网关历史消息 → 统一导出行（把 text/thinking/toolCall 内容展平为可读文本）。
    static func exportItem(from message: SessionHistoryMessage) -> SessionExportMessage {
        let parts: [String] = message.content.compactMap { content in
            switch content.type {
            case "text":
                guard let text = content.text, !text.isEmpty else { return nil }
                return text
            case "thinking":
                guard let thinking = content.thinking, !thinking.isEmpty else { return nil }
                return "💭 思考：\(thinking)"
            case "toolCall":
                let name = content.name ?? "工具"
                let params = content.text ?? content.thinking ?? ""
                return "🔧 \(name)：\(params)"
            default:
                return content.text
            }
        }
        return SessionExportMessage(
            role: message.role,
            content: parts.joined(separator: "\n"),
            timestamp: message.timestamp.map { Date(timeIntervalSince1970: $0 / 1000) },
            model: message.model
        )
    }

    static func roleName(_ role: String) -> String {
        switch role.lowercased() {
        case "user":
            return "用户"
        case "assistant", "agent":
            return "智能体"
        default:
            return role
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - 导出页

/// 会话/频道导出：文本 / Markdown / JSON 三种格式，ShareLink 分享导出文件。
struct SessionExportView: View {
    @Bindable var viewModel: ToolsViewModel
    let source: SessionExportSource

    @State private var messages: [SessionExportMessage] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var format: SessionExportFormat = .text
    @State private var exportFileURL: URL?

    private var exportData: SessionExportData? {
        guard !messages.isEmpty else { return nil }
        return SessionExportData(
            title: source.displayTitle,
            messages: messages,
            exportedAt: Date()
        )
    }

    var body: some View {
        Group {
            if isLoading && messages.isEmpty {
                ProgressView("正在加载消息...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("重试") {
                        Task { await loadMessages() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if messages.isEmpty {
                ContentUnavailableView(
                    "暂无消息可导出",
                    systemImage: "square.and.arrow.up",
                    description: Text("该会话还没有可导出的消息。")
                )
            } else {
                exportContent
            }
        }
        .navigationTitle("导出会话")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if messages.isEmpty && loadError == nil {
                await loadMessages()
            }
        }
    }

    private var exportContent: some View {
        VStack(spacing: 12) {
            Picker("格式", selection: $format) {
                ForEach(SessionExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .onChange(of: format) {
                rebuildExportFile()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("「\(source.displayTitle)」 · 共 \(messages.count) 条消息")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let content = currentExportText {
                        Text(content)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
            }

            if let url = exportFileURL {
                ShareLink(item: url, preview: SharePreview("\(source.displayTitle) · \(format.rawValue)")) {
                    Label("分享导出文件", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    private var currentExportText: String? {
        guard let data = exportData else { return nil }
        return SessionExportBuilder.content(for: format, export: data)
    }

    // MARK: - 加载

    @MainActor
    private func loadMessages() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let items: [SessionExportMessage]
            switch source {
            case .channel(let channel):
                items = ConversationStore.shared.load(channelId: channel.id).map { message in
                    SessionExportMessage(
                        role: message.role.rawValue,
                        content: message.content,
                        timestamp: message.timestamp,
                        model: message.modelName
                    )
                }
            case .gatewaySession(let session, _):
                await viewModel.getSessionHistory(sessionKey: session.key, limit: 500)
                if let history = viewModel.sessionHistory {
                    items = history.messages.map(SessionExportBuilder.exportItem(from:))
                } else if let error = viewModel.errorMessage {
                    throw SessionExportError.loadFailed(error)
                } else {
                    throw SessionExportError.emptyHistory
                }
            }
            messages = items
            rebuildExportFile()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func rebuildExportFile() {
        guard let data = exportData else {
            exportFileURL = nil
            return
        }
        let content = SessionExportBuilder.content(for: format, export: data)
        let fileName = "\(safeFileName(source.displayTitle)).\(format.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try content.data(using: .utf8)?.write(to: url, options: .atomic)
            exportFileURL = url
        } catch {
            exportFileURL = nil
        }
    }

    private func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "会话" : cleaned
    }
}

// MARK: - 导出入口选择页（网关会话 + 本地频道）

struct SessionExportPickerView: View {
    @Bindable var viewModel: ToolsViewModel
    @Environment(\.dismiss) private var dismiss

    private var channels: [Channel] {
        ChannelStore.shared.channels
    }

    var body: some View {
        NavigationStack {
            List {
                Section("本地频道") {
                    if channels.isEmpty {
                        Text("暂无频道")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(channels) { channel in
                            NavigationLink {
                                SessionExportView(viewModel: viewModel, source: .channel(channel))
                            } label: {
                                Label(channel.name, systemImage: "bubble.left.and.bubble.right")
                            }
                        }
                    }
                }

                Section("网关会话") {
                    if viewModel.sessions.isEmpty {
                        Text("暂无网关会话")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.sessions) { session in
                            NavigationLink {
                                SessionExportView(
                                    viewModel: viewModel,
                                    source: .gatewaySession(session, title: Self.sessionTitle(viewModel, session))
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.sessionTitle(viewModel, session))
                                        .font(.body)
                                    if let updatedAt = session.updatedAt {
                                        Text(Self.relativeTime(updatedAt))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("导出会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private static func sessionTitle(_ viewModel: ToolsViewModel, _ session: SessionEntry) -> String {
        viewModel.sessionTitles[session.key]
            ?? ToolsViewModel.friendlyTitle(for: session.key)
            ?? "会话 \(session.key.suffix(8))"
    }

    private static func relativeTime(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
