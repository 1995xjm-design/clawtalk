import AVFoundation
import Foundation

/// Talk push-to-talk capability mirroring official OpenClawTalkCommand:
/// talk.ptt.start / stop / cancel / once.
/// Backed by LongAudioRecorder (PTT) / AudioCaptureManager VAD (once) + AppleSTTService.
final class TalkCapability {
    static let shared = TalkCapability()
    private init() {}

    private var recorder: LongAudioRecorder?
    private var vadManager: AudioCaptureManager?
    private var activeCaptureID: String?
    private let stt = AppleSTTService()

    struct StartResult: Encodable {
        let captureId: String
    }

    struct StopResult: Encodable {
        let captureId: String
        let transcript: String?
        let status: String
    }

    enum TalkError: LocalizedError {
        case busy
        case notRecording
        case micFailed(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "TALK_BUSY: another push-to-talk capture is active"
            case .notRecording: return "TALK_NOT_RECORDING: no active capture"
            case .micFailed(let msg): return msg
            }
        }
    }

    // MARK: - PTT

    /// talk.ptt.start: begin capturing from the microphone.
    func start() throws -> StartResult {
        guard recorder == nil else { throw TalkError.busy }
        let r = LongAudioRecorder()
        do {
            try r.start()
        } catch {
            throw TalkError.micFailed("mic start failed: \(error.localizedDescription)")
        }
        let captureId = UUID().uuidString
        recorder = r
        activeCaptureID = captureId
        return StartResult(captureId: captureId)
    }

    /// talk.ptt.stop: stop capturing and transcribe what was recorded.
    func stop() async throws -> StopResult {
        guard let r = recorder else { throw TalkError.notRecording }
        recorder = nil
        let captureId = activeCaptureID ?? UUID().uuidString
        activeCaptureID = nil
        let samples = r.stop()
        var transcript: String?
        if !samples.isEmpty {
            transcript = try? await stt.transcribe(audioSamples: samples)
        }
        return StopResult(captureId: captureId, transcript: transcript, status: "completed")
    }

    /// talk.ptt.cancel: stop capturing and discard the audio.
    func cancel() throws -> StopResult {
        guard let r = recorder else { throw TalkError.notRecording }
        recorder = nil
        let captureId = activeCaptureID ?? UUID().uuidString
        activeCaptureID = nil
        _ = r.stop()
        return StopResult(captureId: captureId, transcript: nil, status: "cancelled")
    }

    /// talk.ptt.once: capture a single utterance via VAD, then transcribe it.
    func once() async throws -> StopResult {
        guard recorder == nil, vadManager == nil else { throw TalkError.busy }
        let captureId = UUID().uuidString
        activeCaptureID = captureId
        let manager = AudioCaptureManager()
        do {
            try manager.startRecording()
        } catch {
            throw TalkError.micFailed("mic start failed: \(error.localizedDescription)")
        }
        vadManager = manager

        let latch = ResumeLatch<[Float]>()
        manager.enableVAD(
            onUtterance: { samples in latch.resume(samples) },
            onAudioChunk: nil,
            onInterrupt: { latch.resume([]) }
        )

        let samples: [Float] = try await withTaskCancellationHandler {
            await latch.wait()
        } onCancel: {
            latch.resume([])
        }
        manager.stopContinuousRecording()
        vadManager = nil
        activeCaptureID = nil

        var transcript: String?
        if !samples.isEmpty {
            transcript = try? await stt.transcribe(audioSamples: samples)
        }
        return StopResult(captureId: captureId, transcript: transcript, status: "completed")
    }

    /// Cancellation hook for node.invoke.cancel while talk.ptt.once is waiting on VAD.
    func cancelActive() {
        guard let manager = vadManager else { return }
        manager.stopContinuousRecording()
        vadManager = nil
        activeCaptureID = nil
    }

    // MARK: - TTS (chat.push speak)

    private static var speechSynthesizer: AVSpeechSynthesizer?

    /// Speak a chat.push text with the system TTS voice.
    static func speak(text: String) {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "zh-CN")
        speechSynthesizer = synthesizer
        synthesizer.speak(utterance)
    }
}

/// Minimal continuation latch so VAD callbacks resume exactly once, even if
/// the interrupt path fires after the utterance path.
private final class ResumeLatch<Value> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var stored: Value?
    private var resumed = false

    func resume(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        stored = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func wait() async -> Value {
        await withCheckedContinuation { (cont: CheckedContinuation<Value, Never>) in
            lock.lock()
            defer { lock.unlock() }
            if resumed, let stored {
                cont.resume(returning: stored)
            } else {
                continuation = cont
            }
        }
    }
}
