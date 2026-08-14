import Foundation

/// 语音输入模式：短语音（按住说话）/ 长录音（点按开始结束）。
enum VoiceInputMode: String, CaseIterable, Identifiable {
    case short
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return "短语音"
        case .long: return "长录音"
        }
    }

    var hint: String {
        switch self {
        case .short: return "按住说话，松开识别（最长 60 秒）"
        case .long: return "点按开始/结束，长录音最长 60 分钟，支持切后台继续"
        }
    }
}

/// 语音输入阶段（UI 状态）：空闲 / 录音中 / 转写中。
enum VoiceInputPhase: Equatable {
    case idle
    case recording
    case transcribing
}

/// 一次录音捕获结果：PCM 样本（16kHz 单声道 Float32）+ 时长。
struct VoiceInputCapture {
    let samples: [Float]
    let duration: TimeInterval
}

/// 按住说话手势落点动作（微信弧形选择层命中结果）。
enum VoiceInputGestureAction: Equatable {
    case cancel
    case send
    case transcribe
}
