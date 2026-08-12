import SwiftUI

/// 随身语音助手「场景模式」。
///
/// - normal：普通（默认字号 / 正常亮度 / 正常音量）
/// - driving：开车（大字 + 屏幕常亮，减少看屏幕次数）
/// - night：夜间（暗色界面 + 轻声播报，不打扰）
///
/// 说明：任务要求「设置存在 AppSettings」，但为避免并行修改冲突，
/// 本文件不改 `Models/AppSettings.swift`，只提供枚举与场景参数；
/// 需要持久化时请主智能体按文件底部 TODO 在 AppSettings 增加字段。
enum VoiceSceneMode: String, CaseIterable, Identifiable, Codable {
    case normal
    case driving
    case night

    var id: String { rawValue }

    /// 场景名（设置页选择器 / 卡片角标用）。
    var displayName: String {
        switch self {
        case .normal: return "普通"
        case .driving: return "开车"
        case .night: return "夜间"
        }
    }

    /// 状态文字字号缩放：开车大字（常亮场景），夜间略放大。
    var statusFontScale: CGFloat {
        switch self {
        case .normal: return 1.0
        case .driving: return 1.3
        case .night: return 1.15
        }
    }

    /// 卡片亮度调节（0 = 不变，负值 = 变暗）：夜间暗色。
    var cardBrightnessAdjustment: Double {
        switch self {
        case .normal, .driving: return 0
        case .night: return -0.18
        }
    }

    /// 是否保持屏幕常亮（开车 / 夜间驾驶，避免对话中途锁屏）。
    /// 接线方在开始/结束对讲时据此设置 `UIApplication.shared.isIdleTimerDisabled`。
    var keepsScreenAwake: Bool {
        self == .driving || self == .night
    }

    /// 是否用「轻声」播报（夜间）：映射到 AudioPlaybackManager 的
    /// duckVolume（音量 0.3）/ restoreVolume（音量 1.0）。
    var usesQuietVoice: Bool {
        self == .night
    }

    /// 场景一句话提示（卡片底部小字）。
    var hint: String {
        switch self {
        case .normal: return "轻点卡片开始连续对讲"
        case .driving: return "大字常亮 · 专注路况"
        case .night: return "暗色轻声 · 不打扰"
        }
    }
}

// MARK: - AppSettings 持久化（待主智能体接线）

// TODO(主智能体)：如需记住用户上次选择的场景模式，请在 `Models/AppSettings.swift` 增加：
//
//   var voiceAssistantScene: VoiceSceneMode = .normal
//
// 并在 `init(from:)` 里用 `decodeIfPresent ?? .normal` 兼容旧数据、`encode(to:)` 里写出，
// 设置页再补一个 Picker。接线完成前 VoiceAssistantViewModel.sceneMode 默认 .normal，由宿主页面直接赋值。

// MARK: - 语音大卡主题（5 套）

/// 语音大卡底部动态条样式。
enum VoiceAssistantBarStyle: String, CaseIterable, Identifiable, Codable {
    case waveform
    case bars
    case dots
    case line
    case spark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .waveform: return "波浪"
        case .bars: return "声柱"
        case .dots: return "光点"
        case .line: return "细线"
        case .spark: return "星尘"
        }
    }
}

/// 语音大卡主题底色渐变 / 动态条样式 / 待机幅度 / 动画速度各不相同。
/// 持久化：VoiceAssistantCardView 用 @AppStorage("voiceAssistant.theme") 保存 rawValue。
enum VoiceAssistantTheme: String, CaseIterable, Identifiable, Codable {
    case aurora
    case ocean
    case sunset
    case forest
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aurora: return "极光"
        case .ocean: return "深海"
        case .sunset: return "落日"
        case .forest: return "森林"
        case .mono: return "暗夜"
        }
    }

    /// 整卡彩带渐变（SiriBackgroundLayer 主色带）。
    var ribbonColors: [Color] {
        switch self {
        case .aurora:
            return [
                Color(red: 0.62, green: 0.10, blue: 0.22),
                Color(red: 0.50, green: 0.10, blue: 0.62),
                Color(red: 0.08, green: 0.28, blue: 0.62),
                Color(red: 0.62, green: 0.10, blue: 0.22)
            ]
        case .ocean:
            return [
                Color(red: 0.05, green: 0.45, blue: 0.55),
                Color(red: 0.10, green: 0.55, blue: 0.75),
                Color(red: 0.05, green: 0.25, blue: 0.55),
                Color(red: 0.05, green: 0.45, blue: 0.55)
            ]
        case .sunset:
            return [
                Color(red: 0.90, green: 0.45, blue: 0.15),
                Color(red: 0.80, green: 0.25, blue: 0.45),
                Color(red: 0.55, green: 0.15, blue: 0.55),
                Color(red: 0.90, green: 0.45, blue: 0.15)
            ]
        case .forest:
            return [
                Color(red: 0.10, green: 0.45, blue: 0.25),
                Color(red: 0.05, green: 0.55, blue: 0.45),
                Color(red: 0.02, green: 0.25, blue: 0.30),
                Color(red: 0.10, green: 0.45, blue: 0.25)
            ]
        case .mono:
            return [
                Color(red: 0.25, green: 0.27, blue: 0.32),
                Color(red: 0.15, green: 0.17, blue: 0.22),
                Color(red: 0.08, green: 0.09, blue: 0.12),
                Color(red: 0.25, green: 0.27, blue: 0.32)
            ]
        }
    }

    /// 底部动态条样式。
    var barStyle: VoiceAssistantBarStyle {
        switch self {
        case .aurora: return .waveform
        case .ocean: return .bars
        case .sunset: return .dots
        case .forest: return .line
        case .mono: return .spark
        }
    }

    /// 待机（无麦克风引擎）时的低幅起伏幅度：0.0~1.0，越小越安静。
    var idleAmplitude: Double {
        switch self {
        case .aurora: return 0.10
        case .ocean: return 0.14
        case .sunset: return 0.12
        case .forest: return 0.08
        case .mono: return 0.06
        }
    }

    /// 待机动画速度（波浪/光点漂移的快慢）。
    var idleSpeed: Double {
        switch self {
        case .aurora: return 0.9
        case .ocean: return 1.2
        case .sunset: return 1.0
        case .forest: return 0.7
        case .mono: return 1.4
        }
    }

    /// 悬浮光点整体亮度系数（0.6~1.4，暗夜主题调低让彩带更沉）。
    var particleOpacity: Double {
        switch self {
        case .aurora: return 1.0
        case .ocean: return 1.1
        case .sunset: return 1.0
        case .forest: return 0.8
        case .mono: return 0.6
        }
    }

    /// 底部动态条白色透明度（暗夜主题更亮、更醒目）。
    var barOpacity: Double {
        switch self {
        case .aurora: return 0.34
        case .ocean: return 0.38
        case .sunset: return 0.36
        case .forest: return 0.30
        case .mono: return 0.50
        }
    }
}
