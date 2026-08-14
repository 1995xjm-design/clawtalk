import SwiftUI

/// 语音助手大卡内容协议。
///
/// 语音助手组实现本协议（内容本身是 View），并通过
/// VoiceAssistantCardSlot(content:) 注入真实卡片内容；
/// 未注入前由本组显示占位内容（波形图标 + 「点按说话」）。
///
/// 槽位统一提供：渐变大卡外壳、空闲呼吸动画、圆角与阴影，
/// 语音助手组只需实现内容与交互。
protocol VoiceAssistantCardContent: View {
    /// 大卡主标题（语音助手组可覆盖，默认「随身语音助手」）
    var cardTitle: String { get }
    /// 大卡副标题（语音助手组可覆盖，默认「点按说话 · 随时召唤」）
    var cardSubtitle: String { get }
}

extension VoiceAssistantCardContent {
    var cardTitle: String { "随身语音助手" }
    var cardSubtitle: String { "点按说话 · 随时召唤" }
}

/// 顶部语音助手大卡槽位：呼吸动画容器 + 占位内容。
struct VoiceAssistantCardSlot: View {
    private let content: (any VoiceAssistantCardContent)?

    init(content: (any VoiceAssistantCardContent)? = nil) {
        self.content = content
    }

    @State private var isBreathing = false

    var body: some View {
        cardContent
            .frame(maxWidth: .infinity)
            .padding(.vertical, 0)
            .padding(.horizontal, 0)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.openClawRed, .openClawDarkRed],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(
                color: .openClawRed.opacity(0.35),
                radius: isBreathing ? 12 : 6,
                x: 0,
                y: 8
            )
            .scaleEffect(isBreathing ? 1.0 : 0.97)
            .opacity(isBreathing ? 1.0 : 0.88)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("随身语音助手")
    }

    /// 已注入内容优先，否则显示占位内容。
    private var cardContent: AnyView {
        if let content {
            AnyView(content)
        } else {
            AnyView(VoiceAssistantCardPlaceholder())
        }
    }
}

/// 语音助手大卡占位内容：麦克风图标 + 「点按说话」。
private struct VoiceAssistantCardPlaceholder: VoiceAssistantCardContent {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))

            VStack(spacing: 4) {
                Text(cardTitle)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                Text(cardSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}
