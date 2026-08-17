import SwiftUI

/// 唤醒词命中顶部提示条（官方对齐 VoiceWakeToast，UI 用 ClawTalk 主题）。
struct VoiceWakeToast: View {
    var command: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(command)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityLabel("语音唤醒已触发")
        .accessibilityValue("指令：\(command)")
    }
}
