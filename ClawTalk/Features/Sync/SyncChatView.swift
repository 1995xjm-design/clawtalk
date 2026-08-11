import SwiftUI
import MarkdownUI

/// 三端同步聊天页：手机 / 电脑 AutoClaw / 桌面 AI 统一对话历史。
/// 数据源为桥的 GET /sync（codex 18991 / claude 18992），每 3 秒轮询增量刷新；
/// 底部输入框发送走网关 chat（model=openclaw:<agentId>），回复由桥写入 /sync 后轮询带回。
struct SyncChatView: View {
    @Bindable var viewModel: SyncChatViewModel
    var onBack: (() -> Void)?

    @State private var textInput = ""
    @FocusState private var isInputFocused: Bool

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
                                : nil
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
            .onChange(of: viewModel.messages.count) {
                scrollToBottom(using: proxy)
            }
            .onChange(of: viewModel.messages.last?.content) {
                scrollToBottom(using: proxy)
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
                    .font(.system(size: 48))
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

            HStack(spacing: 10) {
                TextField("消息…", text: $textInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                if !textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: {
                        let text = textInput
                        textInput = ""
                        isInputFocused = false
                        viewModel.send(text)
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(.openClawRed)
                    }
                    .disabled(viewModel.isSending)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(Color(.secondarySystemBackground))
    }
}

/// 聊天气泡：样式对齐现有 ChatView（用户右侧红底白字，AI 左侧灰底 Markdown）
private struct SyncBubble: View {
    let message: SyncMessage
    var onRetry: (() -> Void)?

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
                        Text(message.timestamp, style: .time)
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
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if isUser {
            Text(message.content)
                .font(.body)
                .foregroundStyle(.white)
        } else {
            Markdown(message.content)
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
