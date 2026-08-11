import SwiftUI

/// 频道选择页：读取 App Group 中主 App 写入的频道列表，选中即写入待发消息。
struct ShareChannelPickerView: View {
    let payload: SharePayload
    let onFinish: (ShareAction) -> Void

    enum ShareAction {
        case cancelled
        case saved
        case failed(String)
    }

    @State private var channels: [ShareChannel] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在加载频道…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if channels.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        previewSection
                    }
                    Section("选择频道") {
                        ForEach(channels) { channel in
                            Button {
                                savePendingMessage(to: channel)
                            } label: {
                                HStack {
                                    Text(channel.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("发送到 ClawTalk")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    onFinish(.cancelled)
                }
            }
        }
        .task {
            loadChannels()
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(payload.text.isEmpty ? "共享内容" : payload.text)
                .font(.subheadline)
                .lineLimit(3)
            if !payload.attachments.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                    Text("\(payload.attachments.count) 个附件")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("暂无频道")
                .font(.headline)
            Text("请先打开 ClawTalk 添加频道，频道列表会自动同步到分享面板。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadChannels() {
        let defaults = UserDefaults(suiteName: ShareAppGroup.suiteName)
        var result: [ShareChannel] = []
        if let data = defaults?.data(forKey: ShareAppGroup.channelsKey),
           let decoded = try? JSONDecoder().decode([ShareChannel].self, from: data) {
            result = decoded
        }
        channels = result
        isLoading = false
    }

    private func savePendingMessage(to channel: ShareChannel) {
        let message = PendingShareMessage(
            channelId: channel.id,
            channelName: channel.name,
            text: payload.text,
            attachments: payload.attachments,
            createdAt: Date().timeIntervalSince1970
        )
        guard let defaults = UserDefaults(suiteName: ShareAppGroup.suiteName) else {
            onFinish(.failed("App Group 不可用，请重试"))
            return
        }
        do {
            let data = try JSONEncoder().encode(message)
            defaults.set(data, forKey: ShareAppGroup.pendingMessageKey)
            defaults.set(true, forKey: ShareAppGroup.pendingFlagKey)
            defaults.synchronize()
            onFinish(.saved)
        } catch {
            onFinish(.failed("写入待发消息失败，请重试"))
        }
    }
}