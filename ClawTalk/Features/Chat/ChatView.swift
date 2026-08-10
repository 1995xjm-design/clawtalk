import SwiftUI
import PhotosUI

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
    @State private var dragOffset: CGFloat = 0

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
        .offset(x: max(0, dragOffset))
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
                Text("Hands-free conversation")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Tap the icon again to stop.")
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
                        Text("Channels")
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
            Button("Clear Chat", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all messages in this channel. This cannot be undone.")
        }
        .alert("Delete this channel?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                onDeleteChannel?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete the channel and all its messages. This cannot be undone.")
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(
                            message: message,
                            showTokenUsage: settingsStore.settings.showTokenUsage,
                            onRetry: message.hasFailed ? { viewModel.retryMessage(id: message.id) } : nil,
                            onDelete: { viewModel.deleteMessage(id: message.id) }
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
            // 自定义左缘右滑返回：仅拦截屏幕左缘 40pt 内开始的横向右滑
            .simultaneousGesture(edgeSwipeBackGesture)
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

    // 左缘右滑返回手势：从屏幕左缘约 40pt 内开始、横向为主且右移超过 60pt 时触发返回
    private var edgeSwipeBackGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard value.startLocation.x <= 40 else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard dx > 0, abs(dx) > abs(dy) else { return }
                dragOffset = dx
            }
            .onEnded { value in
                guard value.startLocation.x <= 40 else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard dx > 0, abs(dx) > abs(dy) else { return }
                let screenWidth = UIScreen.main.bounds.width
                if dx > screenWidth / 3 {
                    withAnimation(.easeOut(duration: 0.25)) {
                        dragOffset = screenWidth
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        onBack?()
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = 0
                    }
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

            HStack(spacing: 10) {
                attachmentsMenu

                TextField("Message…", text: $textInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .disabled(viewModel.isConversationMode)
                    .opacity(viewModel.isConversationMode ? 0.5 : 1.0)

                if !viewModel.isConversationMode {
                    let trimmed = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let hasText = !trimmed.isEmpty
                    let hasAttachments = !attachedImages.isEmpty

                    // Mic is visible whenever there's no typed text — even with
                    // attachments, so users can dictate a message to send
                    // alongside their photos. Hidden entirely if the user has
                    // turned voice input off in Settings.
                    // 朗读开关：静音 / 恢复朗读（普通聊天快捷控制）
                    Button {
                        if settingsStore.settings.hapticsEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        let wasOn = settingsStore.settings.voiceOutputEnabled
                        settingsStore.settings.voiceOutputEnabled = !wasOn
                        settingsStore.save()
                        if wasOn {
                            viewModel.stopSpeaking()
                        }
                    } label: {
                        Image(systemName: settingsStore.settings.voiceOutputEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.title3)
                            .foregroundStyle(settingsStore.settings.voiceOutputEnabled ? Color.openClawRed : Color.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .help(settingsStore.settings.voiceOutputEnabled ? "朗读已开启，点击静音" : "朗读已静音，点击开启")

                    if !hasText && settingsStore.settings.voiceInputEnabled {
                        InlineMicButton(
                            state: viewModel.state,
                            hapticsEnabled: settingsStore.settings.hapticsEnabled,
                            onTap: {
                                if viewModel.state == .recording {
                                    viewModel.stopRecordingAndSend(images: attachedImages)
                                    attachedImages = []
                                    selectedPhotos = []
                                } else {
                                    viewModel.startRecording()
                                }
                            },
                            onHoldStart: { viewModel.startRecording() },
                            onHoldEnd: {
                                viewModel.stopRecordingAndSend(images: attachedImages)
                                attachedImages = []
                                selectedPhotos = []
                            }
                        )
                    }

                    // Send arrow appears when there's something to send (text or
                    // attachments). With only attachments, mic + send coexist
                    // so users can pick voice or text-less send. When voice is
                    // disabled, also show send for an empty input as a no-op
                    // disabled state — better than a totally bare input row.
                    let voiceOff = !settingsStore.settings.voiceInputEnabled
                    if hasText || hasAttachments || voiceOff {
                        Button(action: {
                            if settingsStore.settings.hapticsEnabled {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            viewModel.sendText(textInput, images: attachedImages)
                            textInput = ""
                            attachedImages = []
                            selectedPhotos = []
                        }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title)
                                .foregroundStyle(.openClawRed)
                        }
                        .disabled(!(viewModel.state == .idle || viewModel.state == .speaking || viewModel.state == .streaming))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
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
                Text("Listening...")
            case .transcribing:
                ProgressView()
                    .scaleEffect(0.8)
                Text("Transcribing...")
            case .thinking:
                ProgressView()
                    .scaleEffect(0.8)
                Text("Thinking...")
            case .streaming:
                Circle()
                    .fill(.openClawRed)
                    .frame(width: 8, height: 8)
                    .modifier(PulsingModifier())
                Text("Responding...")
            case .speaking:
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.openClawRed)
                    .symbolEffect(.variableColor.iterative)
                Text("Speaking...")
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

            Text("Type a message, or tap the\nmic to use voice input.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    @State private var showPhotosPicker = false

    private var attachmentsMenu: some View {
        Menu {
            Button {
                showPhotosPicker = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            // Future attachment types (files, camera, etc.) hang here.
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.openClawRed)
        }
        .photosPicker(isPresented: $showPhotosPicker,
                      selection: $selectedPhotos,
                      maxSelectionCount: 8,
                      matching: .images)
        .onChange(of: selectedPhotos) {
            Task { await loadSelectedPhotos() }
        }
        .disabled(viewModel.isConversationMode)
        .opacity(viewModel.isConversationMode ? 0.5 : 1.0)
    }

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
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                let resized = uiImage.resizedToFit(maxDimension: 512)
                if let jpeg = resized.jpegData(compressionQuality: 0.4) {
                    newImages.append(jpeg)
                }
            }
        }
        attachedImages = newImages
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
