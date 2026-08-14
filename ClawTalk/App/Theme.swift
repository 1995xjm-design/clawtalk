import SwiftUI
import MarkdownUI

extension Color {
    /// OpenClaw brand red — warm, slightly orange-tinted red like a lobster
    static let openClawRed = Color(red: 0.85, green: 0.18, blue: 0.15)

    /// Darker variant for gradients / pressed states
    static let openClawDarkRed = Color(red: 0.65, green: 0.12, blue: 0.10)
}

extension ShapeStyle where Self == Color {
    static var openClawRed: Color { .openClawRed }
}
// MARK: - Design Tokens

/// 设计 Token 统一入口：颜色 / 圆角 / 间距。
/// 收敛目标：14 张功能卡 tint 落到 8 色语义表；手写 Color(red:) 全部走 token，视觉零变化。
enum AppTokens {
    // MARK: 颜色 - 功能卡 8 色语义表（HomeCardKind.tint）

    static let cardPurple = Color.purple
    static let cardPink = Color.pink
    static let cardTeal = Color.teal
    static let cardOrange = Color.orange
    static let cardGreen = Color.green
    static let cardIndigo = Color.indigo
    static let cardBlue = Color.blue
    static let cardRed = Color.red

    // MARK: 颜色 - 语音录制态（GlobalVoiceInput）

    static let voiceRecordingRed = Color(red: 0.82, green: 0.16, blue: 0.2)

    // MARK: 颜色 - 语音大卡顶光带（VoiceAssistantCardView）

    static let voiceAuraBlue = Color(red: 0.30, green: 0.55, blue: 1.0)
    static let voiceAuraPurple = Color(red: 0.65, green: 0.40, blue: 1.0)
    static let voiceAuraCyan = Color(red: 0.20, green: 0.85, blue: 0.90)
    static let voiceAuraBlueShadow = Color(red: 0.40, green: 0.55, blue: 1.0)

    // MARK: 颜色 - 语音主题色板（VoiceSceneMode）

    static let voiceAuroraRibbon: [Color] = [
        Color(red: 0.62, green: 0.10, blue: 0.22),
        Color(red: 0.50, green: 0.10, blue: 0.62),
        Color(red: 0.08, green: 0.28, blue: 0.62),
        Color(red: 0.62, green: 0.10, blue: 0.22)
    ]
    static let voiceAuroraAccent = Color(red: 0.62, green: 0.35, blue: 0.95)
    static let voiceAuroraBackground: [Color] = [
        Color(red: 0.02, green: 0.01, blue: 0.10),
        Color(red: 0.05, green: 0.12, blue: 0.32),
        Color(red: 0.22, green: 0.08, blue: 0.38)
    ]

    static let voiceOceanRibbon: [Color] = [
        Color(red: 0.05, green: 0.45, blue: 0.55),
        Color(red: 0.10, green: 0.55, blue: 0.75),
        Color(red: 0.05, green: 0.25, blue: 0.55),
        Color(red: 0.05, green: 0.45, blue: 0.55)
    ]
    static let voiceOceanAccent = Color(red: 0.30, green: 0.80, blue: 0.95)
    static let voiceOceanBackground: [Color] = [
        Color(red: 0.01, green: 0.05, blue: 0.12),
        Color(red: 0.03, green: 0.20, blue: 0.32),
        Color(red: 0.05, green: 0.12, blue: 0.30)
    ]

    static let voiceSunsetRibbon: [Color] = [
        Color(red: 0.90, green: 0.45, blue: 0.15),
        Color(red: 0.80, green: 0.25, blue: 0.45),
        Color(red: 0.55, green: 0.15, blue: 0.55),
        Color(red: 0.90, green: 0.45, blue: 0.15)
    ]
    static let voiceSunsetAccent = Color(red: 1.00, green: 0.55, blue: 0.25)
    static let voiceSunsetBackground: [Color] = [
        Color(red: 0.12, green: 0.02, blue: 0.06),
        Color(red: 0.35, green: 0.10, blue: 0.20),
        Color(red: 0.18, green: 0.04, blue: 0.24)
    ]

    static let voiceForestRibbon: [Color] = [
        Color(red: 0.10, green: 0.45, blue: 0.25),
        Color(red: 0.05, green: 0.55, blue: 0.45),
        Color(red: 0.02, green: 0.25, blue: 0.30),
        Color(red: 0.10, green: 0.45, blue: 0.25)
    ]
    static let voiceForestAccent = Color(red: 0.35, green: 0.85, blue: 0.55)
    static let voiceForestBackground: [Color] = [
        Color(red: 0.01, green: 0.08, blue: 0.06),
        Color(red: 0.05, green: 0.22, blue: 0.16),
        Color(red: 0.03, green: 0.12, blue: 0.18)
    ]

    static let voiceMonoRibbon: [Color] = [
        Color(red: 0.25, green: 0.27, blue: 0.32),
        Color(red: 0.15, green: 0.17, blue: 0.22),
        Color(red: 0.08, green: 0.09, blue: 0.12),
        Color(red: 0.25, green: 0.27, blue: 0.32)
    ]
    static let voiceMonoAccent = Color(red: 0.80, green: 0.82, blue: 0.88)
    static let voiceMonoBackground: [Color] = [
        Color(red: 0.05, green: 0.05, blue: 0.08),
        Color(red: 0.10, green: 0.11, blue: 0.15),
        Color(red: 0.04, green: 0.04, blue: 0.06)
    ]

    // MARK: 颜色 - 内置壁纸（HomeWallpaper）

    static let wallpaperBluePurple: [(CGFloat, CGFloat, CGFloat)] = [(0.30, 0.45, 0.90), (0.55, 0.35, 0.85), (0.75, 0.30, 0.70)]
    static let wallpaperWarm: [(CGFloat, CGFloat, CGFloat)] = [(0.95, 0.45, 0.25), (0.85, 0.22, 0.45), (0.55, 0.15, 0.55)]
    static let wallpaperDark: [(CGFloat, CGFloat, CGFloat)] = [(0.10, 0.12, 0.20), (0.16, 0.18, 0.30), (0.08, 0.10, 0.18)]
    static let wallpaperGlowWhite = UIColor(red: 1, green: 1, blue: 1, alpha: 0.16)

    // MARK: 圆角

    static let cornerRadiusSmall: CGFloat = 8
    static let cornerRadiusMedium: CGFloat = 12
    static let cornerRadiusLarge: CGFloat = 16

    // MARK: 间距

    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 12
    static let spacingLarge: CGFloat = 16
}

// MARK: - Markdown Theme

extension MarkdownUI.Theme {
    static let openClaw = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(16)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(14)
            ForegroundColor(.secondary)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(13)
                    }
                    .padding(12)
            }
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: AppTokens.cornerRadiusSmall))
            .markdownMargin(top: 8, bottom: 8)
        }
        .link {
            ForegroundColor(.openClawRed)
        }
        .strong {
            FontWeight(.semibold)
        }
}
