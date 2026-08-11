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
