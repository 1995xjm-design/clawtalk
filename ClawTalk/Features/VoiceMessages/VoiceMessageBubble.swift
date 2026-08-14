import AVFoundation
import SwiftUI

/// 语音消息气泡（用户侧）：播放/暂停 + 时长 + 转写文字 + 降级标注。
/// 与 MessageBubble 的用户侧样式保持一致（红底圆角、时间戳、失败重试）。
struct VoiceMessageBubble: View {
    let message: Message
    let attachment: VoiceMessageAttachment
    let onRetry: (() -> Void)?
    let onDelete: (() -> Void)?

    @ObservedObject private var player = VoiceMessageAudioPlayer.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: 4) {
                bubbleContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.openClawRed)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack(spacing: 6) {
                    if message.hasFailed {
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

                        // 诚实标注：网关未确认支持语音附件时，消息已降级为文字发送
                        if attachment.sentAsText {
                            Text("已降级为文字发送")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .contextMenu {
            Button(action: {
                UIPasteboard.general.string = attachment.transcript
            }) {
                Label("复制转写", systemImage: "doc.on.doc")
            }

            if let onDelete {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private var bubbleContent: some View {
        HStack(spacing: 10) {
            Button(action: { player.toggle(attachment) }) {
                Image(systemName: player.playingID == attachment.id ? "stop.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.22), in: Circle())
            }
            .accessibilityLabel(player.playingID == attachment.id ? "停止播放" : "播放语音")
            .accessibilityValue(Self.durationText(attachment.duration))


            VStack(alignment: .leading, spacing: 2) {
                Text(Self.durationText(attachment.duration))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if !attachment.transcript.isEmpty {
                    Text(attachment.transcript)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(3)
                }
            }
        }
    }

    static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 语音消息播放器：同一时刻只播放一条，再次点按即停止（本地 WAV 文件回放）。
private final class VoiceMessageAudioPlayer: NSObject, ObservableObject {
    static let shared = VoiceMessageAudioPlayer()

    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    private override init() {
        super.init()
    }

    func toggle(_ attachment: VoiceMessageAttachment) {
        if playingID == attachment.id {
            stop()
            return
        }
        stop()

        guard let audioPlayer = try? AVAudioPlayer(contentsOf: attachment.localFileURL) else { return }
        audioPlayer.delegate = self
        audioPlayer.prepareToPlay()
        // 与工程其他音频一致：playAndRecord + 扬声器（best-effort，失败不阻塞播放）
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try? AVAudioSession.sharedInstance().setActive(true)
        audioPlayer.play()

        player = audioPlayer
        playingID = attachment.id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }
}

extension VoiceMessageAudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playingID = nil
    }
}
