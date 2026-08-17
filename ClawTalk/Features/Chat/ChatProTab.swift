import SwiftUI

/// 聊天 Pro 容器（对齐官方 ChatProTab 精简）：
/// 在聊天页顶部提供模型切换菜单 + 消息朗读/导出等增强入口，不替换现有聊天实现。
/// 导出/朗读使用真实对话记录（ConversationStore），无记录时给出提示，不塞示例假数据。
struct ChatProTab: View {
    var gatewayConnection: GatewayConnection?
    var channelStore: ChannelStore = .shared

    @State private var showShare = false
    @State private var shareURL: URL?
    @State private var notice: String?

    var body: some View {
        List {
            Section("聊天增强") {
                HStack {
                    Label("模型切换", systemImage: "cpu")
                    Spacer()
                    ChatModelControlsMenuItems(currentLabel: "openclaw:main") { _ in }
                }
                Button {
                    shareCurrentTranscript()
                } label: {
                    Label("导出对话记录", systemImage: "square.and.arrow.up")
                }
                Button {
                    speakMessage()
                } label: {
                    Label("朗读消息", systemImage: "speaker.wave.2.fill")
                }
            }
            Section("会话") {
                if let gatewayConnection {
                    NavigationLink {
                        CommandCenterTab(gatewayConnection: gatewayConnection)
                    } label: {
                        Label("会话中心", systemImage: "rectangle.stack")
                    }
                    NavigationLink {
                        SessionDashboardView(gatewayConnection: gatewayConnection, settingsStore: SettingsStore())
                    } label: {
                        Label("会话仪表盘", systemImage: "gauge.with.dots.needle.50percent")
                    }
                }
            }
        }
        .navigationTitle("聊天 Pro")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ChatTranscriptShareSheet(fileURL: shareURL)
            }
        }
    }

    /// 读取当前第一个频道的真实对话记录（无则返回空）。
    private func transcriptMessages() -> [(role: String, text: String)] {
        guard let channel = channelStore.channels.first else { return [] }
        return ConversationStore.shared.load(channelId: channel.id)
            .map { (role: $0.role.rawValue, text: $0.content) }
    }

    private func shareCurrentTranscript() {
        let messages = transcriptMessages()
        if messages.isEmpty {
            notice = "暂无可用对话记录，请先在聊天页完成对话后再导出。"
            return
        }
        if let url = ChatTranscriptExporter.makeTextFile(messages: messages, title: "ClawTalk 对话") {
            shareURL = url
            showShare = true
        }
    }

    private func speakMessage() {
        guard let last = transcriptMessages().last(where: { $0.role == "assistant" }), !last.text.isEmpty else {
            notice = "暂无可用消息，请先在聊天页完成对话后再朗读。"
            return
        }
        if let gatewayConnection {
            Task {
                if let data = try? await ChatMessageSpeechClient.synthesize(text: last.text, gatewayConnection: gatewayConnection) {
                    _ = await ChatMessageSpeechClient.play(data)
                } else {
                    ChatMessageSpeechClient.speakLocally(last.text)
                }
            }
        } else {
            ChatMessageSpeechClient.speakLocally(last.text)
        }
    }
}
