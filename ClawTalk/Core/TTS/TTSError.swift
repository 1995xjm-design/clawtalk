import Foundation

/// ?? TTS ?????OpenClaw / ????????
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
