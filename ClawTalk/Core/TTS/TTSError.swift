import Foundation

/// TTS 错误：OpenClaw 网关 / 本地引擎统一错误类型。
enum TTSError: LocalizedError {
    case httpError(Int)
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "TTS service returned HTTP \(code)."
        case .invalidConfiguration: return "TTS is not configured. Check Settings."
        }
    }
}
