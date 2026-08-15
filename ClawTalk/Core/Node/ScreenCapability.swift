import AVFoundation
import Foundation
import ReplayKit
import UIKit

/// 屏幕能力（任务 A3a）：对齐官方 OpenClaw 协议。
/// - `screen.snapshot`：截取本机屏幕。官方参考 apps/ios/Sources/Screen/ScreenController.swift
///   `snapshotBase64(maxWidth:format:quality:)` + shared/OpenClawKit `OpenClawScreenSnapshotFormat`（jpeg/png），
///   官方响应结构 { format, base64 }；宿主连接层直接编码本结果，故保留 width/height 以兼容宿主既有调用（ScreenStreamView）。
/// - `screen.record`：ReplayKit 录屏。官方参考 apps/ios/Sources/Screen/ScreenRecordService.swift
///   `record(screenIndex:durationMs:fps:includeAudio:outPath:)`，官方响应结构 { format, base64, durationMs, fps, screenIndex, hasAudio }。
enum ScreenCapability {

    enum ScreenSnapshotFormat: String {
        case jpeg
        case png
    }

    struct SnapshotResult: Encodable {
        let imageBase64: String
        let width: Int
        let height: Int
        let format: String
    }

    struct RecordResult: Encodable {
        let format: String
        let base64: String
        let durationMs: Int
        let fps: Double
        let screenIndex: Int?
        let hasAudio: Bool
    }

    enum ScreenError: LocalizedError {
        case noWindow
        case captureFailed
        case recordUnavailable
        case recordFailed(String)
        case writeFailed(String)
        case noFrames
        case invalidScreenIndex(Int)

        var errorDescription: String? {
            switch self {
            case .noWindow: return "没有可捕获的活动窗口"
            case .captureFailed: return "截图失败"
            case .recordUnavailable: return "当前设备不支持屏幕录制"
            case .recordFailed(let message): return "屏幕录制失败：\(message)"
            case .writeFailed(let message): return "视频写入失败：\(message)"
            case .noFrames: return "未捕获到任何画面帧"
            case .invalidScreenIndex(let index): return "无效的屏幕序号：\(index)"
            }
        }
    }

    // MARK: - Snapshot（screen.snapshot）

    @MainActor
    static func snapshot(
        maxWidth: Int = 1024,
        quality: Double = 0.8,
        format: ScreenSnapshotFormat = .jpeg
    ) async throws -> SnapshotResult {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else {
            throw ScreenError.noWindow
        }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }

        let resized = resizeImage(image, maxWidth: maxWidth)

        let clampedQuality = min(1.0, max(0.1, quality))
        let data: Data?
        switch format {
        case .png:
            data = resized.pngData()
        case .jpeg:
            data = resized.jpegData(compressionQuality: clampedQuality)
        }
        guard let data = data else {
            throw ScreenError.captureFailed
        }

        return SnapshotResult(
            imageBase64: data.base64EncodedString(),
            width: Int(resized.size.width),
            height: Int(resized.size.height),
            format: format.rawValue
        )
    }

    private static func resizeImage(_ image: UIImage, maxWidth: Int) -> UIImage {
        let maxW = CGFloat(maxWidth)
        if image.size.width <= maxW { return image }

        let scale = maxW / image.size.width
        let newSize = CGSize(width: maxW, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Record（screen.record，ReplayKit）

    @MainActor
    static func record(
        screenIndex: Int? = nil,
        durationMs: Int? = nil,
        fps: Double? = nil,
        includeAudio: Bool? = nil
    ) async throws -> RecordResult {
        let config = try makeRecordConfig(
            screenIndex: screenIndex,
            durationMs: durationMs,
            fps: fps,
            includeAudio: includeAudio
        )
        let state = ScreenRecordCaptureState()
        do {
            try await startCapture(state: state, config: config)
            do {
                try await Task.sleep(nanoseconds: UInt64(config.durationMs) * 1_000_000)
            } catch {
                try? await stopCapture()
                throw error
            }
            try await stopCapture()
            try await finishCapture(state: state)

            let data = try Data(contentsOf: config.outURL)
            return RecordResult(
                format: "mp4",
                base64: data.base64EncodedString(),
                durationMs: config.durationMs,
                fps: config.fpsValue,
                screenIndex: config.screenIndex,
                hasAudio: config.includeAudio
            )
        } catch {
            await discardCapture(state: state, outputURL: config.outURL)
            throw error
        }
    }

    private struct ScreenRecordConfig: Sendable {
        let durationMs: Int
        let fpsValue: Double
        let includeAudio: Bool
        let screenIndex: Int?
        let outURL: URL
    }

    private static func makeRecordConfig(
        screenIndex: Int?,
        durationMs: Int?,
        fps: Double?,
        includeAudio: Bool?
    ) throws -> ScreenRecordConfig {
        if let index = screenIndex, index != 0 {
            throw ScreenError.invalidScreenIndex(index)
        }
        let duration = clampDurationMs(durationMs)
        let fpsValue = clampFps(fps, maxFps: 30)
        let fpsInt = Int32(fpsValue.rounded())
        let resolvedFps = Double(fpsInt)
        let includeAudio = includeAudio ?? true

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawtalk-screen-record-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)

        return ScreenRecordConfig(
            durationMs: duration,
            fpsValue: resolvedFps,
            includeAudio: includeAudio,
            screenIndex: screenIndex,
            outURL: outURL
        )
    }

    private static func clampDurationMs(
        _ ms: Int?,
        defaultMs: Int = 10000,
        minMs: Int = 250,
        maxMs: Int = 60000
    ) -> Int {
        let value = ms ?? defaultMs
        return min(maxMs, max(minMs, value))
    }

    private static func clampFps(
        _ fps: Double?,
        defaultFps: Double = 10,
        minFps: Double = 1,
        maxFps: Double
    ) -> Double {
        let value = fps ?? defaultFps
        guard value.isFinite else { return defaultFps }
        return min(maxFps, max(minFps, value))
    }

    // MARK: - ReplayKit capture pipeline

    private static let recordQueue = DispatchQueue(label: "com.clawtalk.screenrecord")

    @MainActor
    private static func startCapture(
        state: ScreenRecordCaptureState,
        config: ScreenRecordConfig
    ) async throws {
        let handler = makeCaptureHandler(state: state, config: config)
        let operation = ScreenRecordStartOperation(
            startAction: { completion in
                startReplayKitCapture(
                    includeAudio: config.includeAudio,
                    handler: handler,
                    completion: completion
                )
            },
            stopAction: { completion in
                stopReplayKitCapture(completion)
            }
        )
        try await operation.run()
    }

    @MainActor
    private static func stopCapture() async throws {
        let stopError = await withCheckedContinuation { continuation in
            stopReplayKitCapture { error in
                continuation.resume(returning: error)
            }
        }
        if let stopError {
            throw stopError
        }
    }

    @MainActor
    private static func startReplayKitCapture(
        includeAudio: Bool,
        handler: @escaping ScreenRecordCaptureHandler,
        completion: @escaping ScreenRecordCaptureCompletion
    ) {
        let recorder = RPScreenRecorder.shared()
        recorder.isMicrophoneEnabled = includeAudio
        recorder.startCapture(handler: handler, completionHandler: completion)
    }

    @MainActor
    private static func stopReplayKitCapture(_ completion: @escaping ScreenRecordCaptureCompletion) {
        RPScreenRecorder.shared().stopCapture { error in
            completion(error)
        }
    }

    private static func makeCaptureHandler(
        state: ScreenRecordCaptureState,
        config: ScreenRecordConfig
    ) -> ScreenRecordCaptureHandler {
        { sample, type, error in
            let sampleBox = ScreenRecordUncheckedBox(value: sample)
            state.withLock { captureState in
                guard captureState.acceptingSamples else { return }
                recordQueue.async {
                    let sample = sampleBox.value
                    if let error {
                        state.withLock { captureState in
                            if captureState.handlerError == nil {
                                captureState.handlerError = error
                            }
                        }
                        return
                    }
                    guard CMSampleBufferDataIsReady(sample) else { return }

                    switch type {
                    case .video:
                        handleVideoSample(sample, state: state, config: config)
                    case .audioApp, .audioMic:
                        handleAudioSample(sample, state: state, includeAudio: config.includeAudio)
                    @unknown default:
                        break
                    }
                }
            }
        }
    }

    private static func handleVideoSample(
        _ sample: CMSampleBuffer,
        state: ScreenRecordCaptureState,
        config: ScreenRecordConfig
    ) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let shouldSkip = state.withLock { captureState in
            if let lastVideoTime = captureState.lastVideoTime {
                let delta = CMTimeSubtract(pts, lastVideoTime)
                return delta.seconds < (1.0 / config.fpsValue)
            }
            return false
        }
        if shouldSkip { return }

        if state.withLock({ $0.writer == nil }) {
            prepareWriter(sample: sample, state: state, config: config, pts: pts)
        }

        let videoInput = state.withLock { $0.videoInput }
        let isStarted = state.withLock { $0.started }
        guard let videoInput, isStarted else { return }
        if videoInput.isReadyForMoreMediaData {
            if videoInput.append(sample) {
                state.withLock { captureState in
                    captureState.sawVideo = true
                    captureState.lastVideoTime = pts
                }
            } else {
                let error = state.withLock { $0.writer?.error }
                if let error {
                    state.withLock { captureState in
                        if captureState.handlerError == nil {
                            captureState.handlerError = ScreenError.writeFailed(error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    private static func prepareWriter(
        sample: CMSampleBuffer,
        state: ScreenRecordCaptureState,
        config: ScreenRecordConfig,
        pts: CMTime
    ) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
            state.withLock { captureState in
                if captureState.handlerError == nil {
                    captureState.handlerError = ScreenError.recordFailed("缺少图像缓冲")
                }
            }
            return
        }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        do {
            let writer = try AVAssetWriter(outputURL: config.outURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else {
                throw ScreenError.writeFailed("无法添加视频输入")
            }
            writer.add(videoInput)

            if config.includeAudio {
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    state.withLock { captureState in
                        captureState.audioInput = audioInput
                    }
                }
            }

            guard writer.startWriting() else {
                throw ScreenError.writeFailed(
                    writer.error?.localizedDescription ?? "无法启动写入器"
                )
            }
            writer.startSession(atSourceTime: pts)
            state.withLock { captureState in
                captureState.writer = writer
                captureState.videoInput = videoInput
                captureState.started = true
            }
        } catch {
            state.withLock { captureState in
                if captureState.handlerError == nil {
                    captureState.handlerError = error
                }
            }
        }
    }

    private static func handleAudioSample(
        _ sample: CMSampleBuffer,
        state: ScreenRecordCaptureState,
        includeAudio: Bool
    ) {
        let audioInput = state.withLock { $0.audioInput }
        let isStarted = state.withLock { $0.started }
        guard includeAudio, let audioInput, isStarted else { return }
        if audioInput.isReadyForMoreMediaData {
            _ = audioInput.append(sample)
        }
    }

    private static func finishCapture(state: ScreenRecordCaptureState) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state.withLock { captureState in
                captureState.acceptingSamples = false
                recordQueue.async {
                    do {
                        if let handlerError = state.withLock({ $0.handlerError }) {
                            throw handlerError
                        }
                        let writer = state.withLock { $0.writer }
                        let videoInput = state.withLock { $0.videoInput }
                        let audioInput = state.withLock { $0.audioInput }
                        let sawVideo = state.withLock { $0.sawVideo }
                        guard let writer, let videoInput, sawVideo else {
                            throw ScreenError.noFrames
                        }

                        videoInput.markAsFinished()
                        audioInput?.markAsFinished()
                        let writerBox = ScreenRecordUncheckedBox(value: writer)
                        writer.finishWriting {
                            let writer = writerBox.value
                            if let error = writer.error {
                                continuation.resume(throwing: ScreenError.writeFailed(error.localizedDescription))
                            } else if writer.status != .completed {
                                continuation.resume(throwing: ScreenError.writeFailed("视频最终写入失败"))
                            } else {
                                continuation.resume()
                            }
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private static func discardCapture(
        state: ScreenRecordCaptureState,
        outputURL: URL
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { captureState in
                captureState.acceptingSamples = false
                recordQueue.async {
                    let writer = state.withLock { captureState -> AVAssetWriter? in
                        let writer = captureState.writer
                        captureState.writer = nil
                        captureState.videoInput = nil
                        captureState.audioInput = nil
                        captureState.started = false
                        return writer
                    }
                    writer?.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - ReplayKit 内部状态类型

private typealias ScreenRecordCaptureHandler = @Sendable (CMSampleBuffer, RPSampleBufferType, Error?) -> Void
private typealias ScreenRecordCaptureCompletion = @Sendable (Error?) -> Void

private final class ScreenRecordUncheckedBox<T>: @unchecked Sendable {
    let value: T

    init(value: T) {
        self.value = value
    }
}

private final class ScreenRecordCaptureState: @unchecked Sendable {
    private let lock = NSLock()

    var writer: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var audioInput: AVAssetWriterInput?
    var started = false
    var sawVideo = false
    var lastVideoTime: CMTime?
    var handlerError: Error?
    var acceptingSamples = true

    func withLock<T>(_ body: (ScreenRecordCaptureState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

private final class ScreenRecordStartOperation: @unchecked Sendable {
    private enum Phase {
        case idle
        case starting
        case startRequested
        case cancelling
        case cancelled
        case finished
    }

    private struct State {
        var phase = Phase.idle
        var continuation: CheckedContinuation<Void, Error>?
        var startResult: Result<Void, Error>?
        var stopRequested = false
        var stopCompleted = false
    }

    private let lock = NSLock()
    private var state = State()
    private let startAction: @MainActor @Sendable (@escaping ScreenRecordCaptureCompletion) -> Void
    private let stopAction: @MainActor @Sendable (@escaping ScreenRecordCaptureCompletion) -> Void

    init(
        startAction: @escaping @MainActor @Sendable (@escaping ScreenRecordCaptureCompletion) -> Void,
        stopAction: @escaping @MainActor @Sendable (@escaping ScreenRecordCaptureCompletion) -> Void
    ) {
        self.startAction = startAction
        self.stopAction = stopAction
    }

    @MainActor
    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.begin(continuation)
            }
        }, onCancel: {
            self.cancel()
        })
    }

    private func cancel() {
        self.withLock { state in
            switch state.phase {
            case .idle:
                state.phase = .cancelled
            case .starting, .startRequested:
                state.phase = .cancelling
            case .cancelling, .cancelled, .finished:
                break
            }
        }
    }

    @MainActor
    private func begin(_ continuation: CheckedContinuation<Void, Error>) {
        let shouldStart = self.withLock { state -> Bool in
            switch state.phase {
            case .idle:
                state.phase = .starting
                state.continuation = continuation
                return true
            case .cancelled:
                state.phase = .finished
                return false
            case .starting, .startRequested, .cancelling, .finished:
                preconditionFailure("ReplayKit 录屏启动操作只能运行一次")
            }
        }
        guard shouldStart else {
            continuation.resume(throwing: CancellationError())
            return
        }

        self.startAction { [weak self] error in
            self?.captureDidStart(error: error)
        }

        self.withLock { state in
            switch state.phase {
            case .starting:
                state.phase = .startRequested
            case .cancelling, .finished:
                break
            case .idle, .startRequested, .cancelled:
                break
            }
        }
    }

    private func captureDidStart(error: Error?) {
        let result: Result<Void, Error> = error.map(Result.failure) ?? .success(())
        var shouldStop = false
        let completion = self.withLock { state -> (CheckedContinuation<Void, Error>, Result<Void, Error>)? in
            switch state.phase {
            case .starting, .startRequested:
                state.phase = .finished
                guard let continuation = state.continuation else { return nil }
                state.continuation = nil
                return (continuation, result)
            case .cancelling:
                state.startResult = result
                if case .success = result, !state.stopRequested {
                    state.stopRequested = true
                    shouldStop = true
                }
                return Self.takeCancellationCompletionIfReady(state: &state)
            case .idle, .cancelled, .finished:
                return nil
            }
        }
        if shouldStop {
            Task { @MainActor in self.requestStop() }
        }
        Self.resume(completion)
    }

    @MainActor
    private func requestStop() {
        self.stopAction { [weak self] _ in
            self?.captureStopDidComplete()
        }
    }

    private func captureStopDidComplete() {
        let completion = self.withLock { state -> (CheckedContinuation<Void, Error>, Result<Void, Error>)? in
            guard state.phase == .cancelling else { return nil }
            state.stopCompleted = true
            return Self.takeCancellationCompletionIfReady(state: &state)
        }
        Self.resume(completion)
    }

    private static func takeCancellationCompletionIfReady(
        state: inout State
    ) -> (CheckedContinuation<Void, Error>, Result<Void, Error>)? {
        guard state.phase == .cancelling,
              let startResult = state.startResult,
              let continuation = state.continuation
        else { return nil }

        let cleanupComplete: Bool = switch startResult {
        case .success:
            state.stopRequested && state.stopCompleted
        case .failure:
            true
        }
        guard cleanupComplete else { return nil }

        state.phase = .finished
        state.continuation = nil
        return (continuation, .failure(CancellationError()))
    }

    private static func resume(
        _ completion: (CheckedContinuation<Void, Error>, Result<Void, Error>)?
    ) {
        guard let (continuation, result) = completion else { return }
        continuation.resume(with: result)
    }

    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

// MARK: - Params

struct ScreenSnapshotParams: Decodable {
    let maxWidth: Int?
    let quality: Double?
    let format: String?
}

struct ScreenRecordParams: Decodable {
    let screenIndex: Int?
    let durationMs: Int?
    let fps: Double?
    let format: String?
    let includeAudio: Bool?
}
