import SwiftUI
import MarkdownUI
import PhotosUI
import UniformTypeIdentifiers

/// 三端同步聊天页：手机 / 电脑 AutoClaw / 桌面 AI 统一对话历史。
/// 数据源为桥的 GET /sync（codex 18991 / claude 18992），每 3 秒轮询增量刷新；
/// 底部输入框发送走网关 chat（model=openclaw:<agentId>），回复由桥写入 /sync 后轮询带回。
/// 右上角菜单：查找聊天内容（本地过滤）/ 清空聊天 / 删除频道；删除单条只影响本机显示。
struct SyncChatView: View {
    @Bindable var viewModel: SyncChatViewModel
    var onBack: (() -> Void)?
    var onDeleteChannel: (() -> Void)?

    @State private var textInput = ""
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var showClearConfirm = false
    @State private var showDeleteConfirm = false
    @State private var scrollTargetID: UUID?
    @FocusState private var isInputFocused: Bool
    @State private var showSyncPhotosPicker = false
    @State private var selectedSyncPhotos: [PhotosPickerItem] = []
    @State private var attachedSyncImages: [Data] = []
    @State private var showSyncAttachmentMenu = false
    @State private var showSyncFileImporter = false
    @State private var attachedSyncFile: ChatFileAttachment?
    @State private var syncFileAttachmentError: String?

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider().opacity(0.3)
            messageList
            Divider().opacity(0.3)
            inputArea
        }
        .background(Color(.systemBackground))
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
        .alert("清空聊天记录？", isPresented: $showClearConfirm) {
            Button("清空聊天", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除本机显示：记录清空时间点，之后只显示新消息，不影响电脑端历史。")
        }
        .alert("删除频道？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                onDeleteChannel?()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除该频道及其本机显示记录，此操作无法撤销。")
        }
        .sheet(isPresented: $showSearch) {
            SyncSearchView(messages: viewModel.messages, searchText: $searchText) { message in
                scrollTargetID = message.id
                showSearch = false
            }
        }
    }

    /// 转写结果追加到输入框（与微信式按住说话一致）。
    private func appendTranscript(_ transcript: String) {
        if textInput.isEmpty {
            textInput = transcript
        } else {
            textInput += transcript
        }
    }

    /// 相册多选 → 压缩后存入待发送图片。
    static let allowedFileTypes: [UTType] = [
        .plainText, .delimitedText, .commaSeparatedText, .json, .html, .xml, .pdf
    ]

    private func loadSyncFile(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            LogCollector.record(module: "附件", "同步聊天读取文件失败：\(url.lastPathComponent)")
            syncFileAttachmentError = "读取文件失败，请重试"
            return
        }
        guard data.count <= 5 * 1024 * 1024 else {
            syncFileAttachmentError = "文件超过 5MB 限制"
            return
        }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "txt": mime = "text/plain"
        case "md", "markdown": mime = "text/markdown"
        case "html", "htm": mime = "text/html"
        case "csv": mime = "text/csv"
        case "json": mime = "application/json"
        case "pdf": mime = "application/pdf"
        default:
            syncFileAttachmentError = "暂不支持该类型（支持 txt/md/html/csv/json/pdf）"
            return
        }
        attachedSyncFile = ChatFileAttachment(filename: url.lastPathComponent, mimeType: mime, data: data)
    }

    private func loadSyncPhotos() async {
        var newImages: [Data] = []
        for item in selectedSyncPhotos {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                guard let uiImage = UIImage(data: data) else { continue }
                let resized = uiImage.resizedToFit(maxDimension: 512)
                if let jpeg = resized.jpegData(compressionQuality: 0.4) {
                    newImages.append(jpeg)
                }
            } catch {
                LogCollector.record(module: "图片", "同步聊天图片加载失败：\(AppErrorText.localized(error.localizedDescription))")
            }
        }
        attachedSyncImages = newImages
    }
    /// 同步消息内容渲染防护：超长文本截断、剥离可能导致 MarkdownUI 崩溃的控制字符。
    static func sanitizedContent(_ raw: String) -> String {
        var text = raw
        // 控制字符（除 \n \t）剥离：部分桥写入的内容可能携带异常控制符
        text = text.unicodeScalars.filter { scalar in
            let c = scalar.value
            if c == 10 || c == 9 || c == 13 { return true } // LF / TAB / CR
            return c >= 32
        }.map(String.init).joined()
        // 超长单条（> 20000 字符）截断，避免极端内容导致渲染/内存问题
        if text.count > 20000 {
            text = String(text.prefix(20000)) + "\n\n…（内容过长已截断）"
        }
        return text
    }
    // MARK: - 导航栏

    private var navBar: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(viewModel.channelName)
                    .font(.headline)
                    .fontWeight(.semibold)
                Text("三端同步 · 手机 / 电脑 / 桌面 AI")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(action: { onBack?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                        Text("频道")
                            .font(.body)
                    }
                    .foregroundStyle(.openClawRed)
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                    .padding(.trailing, 4)
                }

                Spacer()

                HStack(spacing: 18) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title)
                            .foregroundStyle(.openClawRed)
                            .contentShape(Rectangle())
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("刷新")

                    Menu {
                        Button(action: { showSearch = true }) {
                            Label("查找聊天内容", systemImage: "magnifyingglass")
                        }
                        Button(action: { showClearConfirm = true }) {
                            Label("清空聊天", systemImage: "trash")
                        }
                        Button(role: .destructive, action: { showDeleteConfirm = true }) {
                            Label("删除频道", systemImage: "minus.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title)
                            .foregroundStyle(.openClawRed)
                            .contentShape(Rectangle())
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.messages) { message in
                        SyncBubble(
                            message: message,
                            onRetry: message.hasSendError
                                ? { viewModel.retryFailedMessage(content: message.content) }
                                : nil,
                            onDelete: { viewModel.deleteMessage(message) }
                        )
                        .id(message.id)
                    }
                }
                .padding(.vertical, 12)
            }
            // 点击聊天区任意位置收起键盘（simultaneousGesture 不会吞掉气泡内按钮点击）
            .simultaneousGesture(
                TapGesture().onEnded { isInputFocused = false }
            )
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .overlay {
                if viewModel.messages.isEmpty {
                    emptyState
                }
            }
            // 进入界面、布局稳定后定位到最新消息
            .onAppear { scrollToBottom(using: proxy) }
            // 轮询新增消息后滚到底部
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(using: proxy)
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                scrollToBottom(using: proxy)
            }
            // 查找聊天内容：点结果后滚动定位到对应消息
            .onChange(of: scrollTargetID) { _, targetID in
                guard let targetID else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        if let lastID = viewModel.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    // MARK: - 空状态 / 服务不可达

    private var emptyState: some View {
        VStack(spacing: 14) {
            if let error = viewModel.errorMessage {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("同步服务不可用")
                    .font(.headline)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(.openClawRed)
            } else {
                Image("LogoRed")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .opacity(0.6)
                Text("暂无同步消息")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("三端统一对话历史会显示在这里。")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 输入区

    private var inputArea: some View {
        VStack(spacing: 0) {
            // 错误提示（服务不可达时保留重试入口）
            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("重试") {
                        Task { await viewModel.refresh() }
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.openClawRed)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            // 发送中提示（发送走网关 chat，回复由 /sync 轮询带回）
            if viewModel.isSending {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("发送中，回复会在同步后自动出现…")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            }

            if !attachedSyncImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachedSyncImages.enumerated()), id: \.offset) { index, data in
                            if let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        Button(action: { attachedSyncImages.remove(at: index) }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.body)
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.6))
                                        }
                                        .accessibilityLabel("删除图片")
                                        .offset(x: 6, y: -6)
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .padding(.top, 4)
            }

            if let attachedSyncFile {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.openClawRed)
                    Text(attachedSyncFile.filename)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        self.attachedSyncFile = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                    .accessibilityLabel("移除附件")
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            WeChatInputBar(
                text: $textInput,
                voiceInputEnabled: true,
                hapticsEnabled: true,
                isSending: viewModel.isSending,
                audioLevel: viewModel.audioLevel,
                isConversationMode: false,
                onToggleVoiceMode: {},
                onSendText: {
                    let text = textInput
                    textInput = ""
                    isInputFocused = false
                    viewModel.send(text, images: attachedSyncImages, file: attachedSyncFile)
                    attachedSyncImages = []
                    attachedSyncFile = nil
                    selectedSyncPhotos = []
                },
                onHoldStart: { viewModel.startVoiceInput() },
                onHoldCancel: { viewModel.cancelVoiceInput() },
                onHoldSendVoice: {
                    viewModel.stopVoiceInputAndTranscribe { transcript in
                        appendTranscript(transcript)
                    }
                },
                onHoldTranscribe: {
                    viewModel.stopVoiceInputAndTranscribe { transcript in
                        appendTranscript(transcript)
                    }
                },
                onAddAttachment: { showSyncAttachmentMenu = true }
            )
            .confirmationDialog("添加附件", isPresented: $showSyncAttachmentMenu, titleVisibility: .visible) {
                Button("照片") { showSyncPhotosPicker = true }
                Button("文件") { showSyncFileImporter = true }
                Button("取消", role: .cancel) {}
            }
            .fileImporter(isPresented: $showSyncFileImporter, allowedContentTypes: SyncChatView.allowedFileTypes) { result in
                switch result {
                case .success(let url):
                    loadSyncFile(from: url)
                case .failure:
                    break
                }
            }
            .alert("附件提示", isPresented: Binding(get: { syncFileAttachmentError != nil }, set: { if !$0 { syncFileAttachmentError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(syncFileAttachmentError ?? "")
            }
            .photosPicker(isPresented: $showSyncPhotosPicker,
                          selection: $selectedSyncPhotos,
                          maxSelectionCount: 8,
                          matching: .images)
            .onChange(of: selectedSyncPhotos) {
                Task { await loadSyncPhotos() }
            }
        }
        .background(Color(.secondarySystemBackground))
    }


}

/// 查找聊天内容：基于已加载消息本地过滤，点结果滚动定位
private struct SyncSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let messages: [SyncMessage]
    @Binding var searchText: String
    let onSelect: (SyncMessage) -> Void

    private var results: [SyncMessage] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        return messages.filter { $0.content.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("未找到匹配消息")
                        .foregroundStyle(.secondary)
                }
                ForEach(results) { message in
                    Button {
                        onSelect(message)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: message.role == .user ? "person.fill" : "cpu")
                                    .font(.caption)
                                    .foregroundStyle(message.role == .user ? .blue : Color.openClawRed)
                                Text(ChatBubbleTimeText.string(from: message.timestamp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(message.content)
                                .font(.subheadline)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("查找聊天内容")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索已加载消息…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

/// 聊天气泡：样式对齐现有 ChatView（用户右侧红底白字，AI 左侧灰底 Markdown）
private struct SyncBubble: View {
    let message: SyncMessage
    var onRetry: (() -> Void)?
    var onDelete: (() -> Void)?

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                bubbleContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack(spacing: 6) {
                    if message.isLocalPending {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("发送中…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if message.hasSendError {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text("发送失败")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        if let onRetry {
                            Button(action: onRetry) {
                                Text("重试")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.openClawRed)
                            }
                        }
                    } else {
                        Text(ChatBubbleTimeText.string(from: message.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .contextMenu {
            Button(action: {
                UIPasteboard.general.string = message.content
            }) {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button(role: .destructive, action: { onDelete?() }) {
                Label("删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if isUser {
            Text(message.content)
                .font(.body)
                .foregroundStyle(.white)
        } else {
            // 防御：超长/畸形内容截断后再交给 MarkdownUI，避免极端内容触发渲染崩溃
            let safeContent = SyncChatView.sanitizedContent(message.content)
            Markdown(safeContent)
                .markdownTheme(.openClaw)
                .textSelection(.enabled)
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if isUser {
            return AnyShapeStyle(Color.openClawRed)
        } else {
            return AnyShapeStyle(Color(.systemGray6))
        }
    }
}
