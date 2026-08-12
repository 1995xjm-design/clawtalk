import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    var settingsStore: SettingsStore
    var gatewayConnection: GatewayConnection?
    var onBack: (() -> Void)?
    var onDeleteChannel: (() -> Void)?
    @State private var textInput = ""
    @State private var showClearConfirm = false
    @State private var showConversationHint = false
    @AppStorage("hasSeenConversationToast") private var hasSeenConversationToast = false
    @State private var showDeleteConfirm = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var attachedImages: [Data] = []
    @FocusState private var isInputFocused: Bool
    @State private var showSearch = false
    @State private var scrollTargetID: UUID?
    @State private var showAttachmentMenu = false
    @State private var showFileImporter = false
    @State private var attachedFile: ChatFileAttachment?
    @State private var fileAttachmentError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Custom nav bar
            navBar
            Divider().opacity(0.3)

            // Chat area
            messageList

            // Input area
            Divider().opacity(0.3)
            inputArea
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            if showConversationHint {
                conversationHintToast
                    .padding(.horizontal, 16)
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showSearch) {
            ChatSearchView(messages: viewModel.messages) { messageID in
                scrollTargetID = messageID
            }
        }
    }

    private var conversationHintToast: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.openClawRed)
            VStack(alignment: .leading, spacing: 2) {
                Text("免提对话")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("再次点按图标可停止。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    // MARK: - Navigation Bar

    private var navBar: some View {
        ZStack {
            // Centered title with connection dot
            HStack(spacing: 6) {
                Text(viewModel.channel.name)
                    .font(.headline)
                    .fontWeight(.semibold)

                if settingsStore.settings.useWebSocket, let gw = gatewayConnection {
                    Circle()
                        .fill(connectionDotColor(gw.connectionState))
                        .frame(width: 8, height: 8)
                }
            }

            // Left/right buttons
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
                    if settingsStore.settings.voiceInputEnabled {
                        Button(action: toggleConversationMode) {
                            Image(systemName: viewModel.isConversationMode
                                  ? "bubble.left.and.bubble.right.fill"
                                  : "bubble.left.and.bubble.right")
                                .font(.title)
                                .foregroundStyle(.openClawRed)
                                .contentShape(Rectangle())
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(viewModel.isConversationMode
                                            ? "Exit hands-free conversation mode"
                                            : "Start hands-free conversation mode")
                    }

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
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .alert("Clear chat history?", isPresented: $showClearConfirm) {
            Button("清空聊天", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除此频道中的所有消息，此操作无法撤销。")
        }
        .alert("Delete this channel?", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                onDeleteChannel?()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除该频道及其所有消息，此操作无法撤销。")
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.messages) { message in
                        if let attachment = viewModel.voiceAttachment(for: message.id) {
                            VoiceMessageBubble(
                                message: message,
                                attachment: attachment,
                                onRetry: message.hasFailed ? { viewModel.retryMessage(id: message.id) } : nil,
                                onDelete: { viewModel.deleteMessage(id: message.id) }
                            )
                            .id(message.id)
                        } else {
                            MessageBubble(
                                message: message,
                                showTokenUsage: settingsStore.settings.showTokenUsage,
                                onRetry: message.hasFailed ? { viewModel.retryMessage(id: message.id) } : nil,
                                onDelete: { viewModel.deleteMessage(id: message.id) }
                            )
                            .id(message.id)
                        }
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
            // 进入界面、布局稳定后定位到最新消息（移除 defaultScrollAnchor(.bottom)，
            // 避免内容不满一屏时被顶出视口导致列表空白）
            .onAppear {
                scrollToBottom(using: proxy)
            }
            // 服务器历史异步加载、整体替换 messages 后也滚到底部
            .onChange(of: viewModel.messages.count) {
                scrollToBottom(using: proxy)
            }
            // 新消息/流式内容变化时保持滚到底部
            .onChange(of: viewModel.messages.last?.content) {
                scrollToBottom(using: proxy)
            }
            // 搜索跳转定位
            .onChange(of: scrollTargetID) { _, newID in
                guard let id = newID else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - 滚动与手势辅助

    // 滚到最新一条消息（无消息时不动作）
    private func scrollToBottom(using proxy: ScrollViewProxy) {
        if let lastID = viewModel.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Inline state indicator (recording/transcribing/thinking/etc.)
            if viewModel.state != .idle {
                stateIndicator
                    .padding(.top, 10)
                    .transition(.opacity)
            }

            // Hands-free TalkButton overlay only while in conversation mode.
            if viewModel.isConversationMode {
                TalkButton(
                    state: viewModel.state,
                    audioLevel: viewModel.audioLevel,
                    hapticsEnabled: settingsStore.settings.hapticsEnabled,
                    onTap: {},
                    onHoldStart: {},
                    onHoldEnd: {}
                )
                .padding(.top, 4)
                .transition(.opacity)
            }

            // Attached image previews
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachedImages.enumerated()), id: \.offset) { index, data in
                            if let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        Button(action: { attachedImages.remove(at: index) }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.6))
                                        }
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

            if let attachedFile {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.openClawRed)
                    Text(attachedFile.filename)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        self.attachedFile = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            WeChatInputBar(
                text: $textInput,
                voiceInputEnabled: settingsStore.settings.voiceInputEnabled,
                hapticsEnabled: settingsStore.settings.hapticsEnabled,
                isSending: viewModel.state == .transcribing || viewModel.state == .thinking,
                audioLevel: viewModel.audioLevel,
                isConversationMode: viewModel.isConversationMode,
                onToggleVoiceMode: {},
                onSendText: {
                    if settingsStore.settings.hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    viewModel.sendText(textInput, images: attachedImages, file: attachedFile)
                    textInput = ""
                    attachedImages = []
                    attachedFile = nil
                    selectedPhotos = []
                },
                onHoldStart: { viewModel.startVoiceMessageRecording() },
                onHoldCancel: { viewModel.cancelVoiceMessageRecording() },
                onHoldSendVoice: { viewModel.stopVoiceMessageRecordingAndSend() },
                onHoldTranscribe: { viewModel.stopVoiceMessageRecordingAndSendTextOnly() },
                onAddAttachment: { showAttachmentMenu = true }
            )
            .confirmationDialog("添加附件", isPresented: $showAttachmentMenu, titleVisibility: .visible) {
                Button("照片") { showPhotosPicker = true }
                Button("文件") { showFileImporter = true }
                Button("取消", role: .cancel) {}
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: Self.allowedFileTypes) { result in
                switch result {
                case .success(let url):
                    loadPickedFile(from: url)
                case .failure:
                    break
                }
            }
            .alert("附件提示", isPresented: Binding(get: { fileAttachmentError != nil }, set: { if !$0 { fileAttachmentError = nil } })) {
                Button("?", role: .cancel) {}
            } message: {
                Text(fileAttachmentError ?? "")
            }
            .photosPicker(isPresented: $showPhotosPicker,
                          selection: $selectedPhotos,
                          maxSelectionCount: 8,
                          matching: .images)
            .onChange(of: selectedPhotos) {
                Task { await loadSelectedPhotos() }
            }
        }
        .background(Color(.secondarySystemBackground))
        .animation(.easeInOut(duration: 0.2), value: viewModel.state)
        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage != nil)
    }

    // MARK: - State Indicator

    private var stateIndicator: some View {
        HStack(spacing: 8) {
            switch viewModel.state {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("正在聆听…")
            case .transcribing:
                ProgressView()
                    .scaleEffect(0.8)
                Text("正在转写…")
            case .thinking:
                ProgressView()
                    .scaleEffect(0.8)
                Text("正在思考…")
            case .streaming:
                Circle()
                    .fill(.openClawRed)
                    .frame(width: 8, height: 8)
                    .modifier(PulsingModifier())
                Text("正在回复…")
            case .speaking:
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.openClawRed)
                    .symbolEffect(.variableColor.iterative)
                Text("正在朗读…")
                Button(action: { viewModel.stopSpeaking() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            case .idle:
                EmptyView()
            }
        }
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(.systemGray5).opacity(0.8))
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image("LogoRed")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .opacity(0.6)

            Text("ClawTalk")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Text("输入消息，或点按麦克风使用语音输入。")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    @State private var showPhotosPicker = false

    private func toggleConversationMode() {
        if settingsStore.settings.hapticsEnabled {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        if viewModel.isConversationMode {
            viewModel.exitConversationMode()
        } else {
            viewModel.enterConversationMode()
            if !hasSeenConversationToast {
                hasSeenConversationToast = true
                withAnimation(.easeInOut(duration: 0.25)) { showConversationHint = true }
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.25)) { showConversationHint = false }
                    }
                }
            }
        }
    }

    private func connectionDotColor(_ state: GatewayConnection.State) -> Color {
        switch state {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .red
        }
    }

    // MARK: - Photo Loading

    private func loadSelectedPhotos() async {
        var newImages: [Data] = []
        for item in selectedPhotos {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    LogCollector.record(module: "图片", "读取所选图片数据失败")
                    continue
                }
                guard let uiImage = UIImage(data: data) else {
                    LogCollector.record(module: "图片", "图片数据无法解码为图像")
                    continue
                }
                let resized = uiImage.resizedToFit(maxDimension: 512)
                if let jpeg = resized.jpegData(compressionQuality: 0.4) {
                    newImages.append(jpeg)
                }
            } catch {
                LogCollector.record(module: "图片", "图片加载失败：\(AppErrorText.localized(error.localizedDescription))")
            }
        }
        attachedImages = newImages
    }

    /// A3 附件文件类型白名单：文本类 + PDF（网关 /v1/responses input_file 支持范围，≤5MB）。
    private static let allowedFileTypes: [UTType] = [
        .plainText, .delimitedText, .commaSeparatedText, .json, .html, .xml, .pdf
    ]

    private func loadPickedFile(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            LogCollector.record(module: "附件", "读取所选文件失败：\(url.lastPathComponent)")
            fileAttachmentError = "读取文件失败，请重试"
            return
        }
        guard data.count <= 5 * 1024 * 1024 else {
            fileAttachmentError = "文件超过 5MB 限制"
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
            fileAttachmentError = "暂不支持该类型（支持 txt/md/html/csv/json/pdf）"
            return
        }
        attachedFile = ChatFileAttachment(filename: url.lastPathComponent, mimeType: mime, data: data)
    }
}

private struct PulsingModifier: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.4 : 1.0)
            .opacity(pulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

// MARK: - Model Picker Sheet

extension UIImage {
    func resizedToFit(maxDimension: CGFloat) -> UIImage {
        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        guard ratio < 1 else { return self }
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
