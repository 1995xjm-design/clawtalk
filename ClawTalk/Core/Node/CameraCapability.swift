import AVFoundation
import Foundation
import os
import UIKit

/// 摄像头能力（任务 A3a）：对齐官方 OpenClaw 协议。
/// - `camera.list`：官方 OpenClawCameraCommand.list，响应结构 { id, name, position, deviceType }。
/// - `camera.snap`：官方 OpenClawCameraCommand.snap，参数 { facing, maxWidth, quality, format, deviceId, delayMs }，
///   响应结构 { format, base64, width, height }；宿主连接层同时用 imageBase64 注入聊天。
/// - `camera.clip`：官方 OpenClawCameraCommand.clip，参数 { facing, durationMs, includeAudio, format, deviceId }，
///   响应结构 { format, base64, durationMs, hasAudio }。
/// 官方参考 apps/ios/Sources/Camera/CameraController.swift（snap/clip/listDevices）+
/// shared/OpenClawKit CameraCapturePipelineSupport / CameraSessionConfiguration / CameraMovieRecordingOperation。
enum CameraCapability {

    struct CameraInfo: Encodable {
        let id: String
        let name: String
        let position: String
        let deviceType: String
    }

    enum CameraImageFormat: String {
        case jpg
        case jpeg
    }

    enum CameraVideoFormat: String {
        case mp4
    }

    struct SnapResult: Encodable {
        let imageBase64: String
        let width: Int
        let height: Int
        let camera: String
        let format: String
    }

    struct ClipResult: Encodable {
        let format: String
        let base64: String
        let durationMs: Int
        let hasAudio: Bool
    }

    enum CameraError: LocalizedError {
        case denied
        case unavailable(String)
        case captureFailed(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .denied: return "相机权限被拒绝"
            case .unavailable(let msg): return msg
            case .captureFailed(let msg): return msg
            case .exportFailed(let msg): return msg
            }
        }
    }

    // MARK: - List Cameras（camera.list）

    static func listCameras() -> [CameraInfo] {
        return discoverySession().devices.map { device in
            CameraInfo(
                id: device.uniqueID,
                name: device.localizedName,
                position: positionLabel(device.position),
                deviceType: device.deviceType.rawValue
            )
        }
    }

    // MARK: - Take Photo（camera.snap）

    static func snap(
        camera: String? = nil,
        facing: String? = nil,
        quality: Double = 0.8,
        maxWidth: Int = 1920,
        format: CameraImageFormat = .jpeg,
        deviceId: String? = nil,
        delayMs: Int = 0
    ) async throws -> SnapResult {
        // Check permission
        try await ensureAccess(for: .video)

        // Find camera device
        let facingValue = camera ?? facing
        let position: AVCaptureDevice.Position = facingValue == "front" ? .front : .back
        guard let device = pickCamera(position: position, deviceId: deviceId) else {
            throw CameraError.unavailable("没有可用的\(facingValue == "front" ? "前置" : "后置")摄像头")
        }

        // Set up capture session
        let session = AVCaptureSession()
        session.sessionPreset = .photo

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            throw CameraError.unavailable("无法访问相机输入")
        }
        guard session.canAddInput(input) else {
            throw CameraError.unavailable("无法将相机输入添加到会话")
        }
        session.addInput(input)

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            throw CameraError.unavailable("无法将照片输出添加到会话")
        }
        session.addOutput(output)

        // Start session and capture
        session.startRunning()

        // Small delay to let camera warm up
        try await Task.sleep(nanoseconds: 150_000_000)

        // Optional pre-capture delay
        let clampedDelayMs = min(max(0, delayMs), 10_000)
        if clampedDelayMs > 0 {
            try await Task.sleep(nanoseconds: UInt64(clampedDelayMs) * 1_000_000)
        }

        let delegate = PhotoCaptureDelegate()
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: delegate)

        let photoData = try await delegate.waitForCapture()
        session.stopRunning()

        guard let image = UIImage(data: photoData) else {
            throw CameraError.captureFailed("无法从拍摄数据创建图像")
        }

        // Resize if needed
        let resized = resizeImage(image, maxWidth: maxWidth)
        let clampedQuality = min(1.0, max(0.05, quality))
        guard let jpegData = resized.jpegData(compressionQuality: clampedQuality) else {
            throw CameraError.captureFailed("JPEG 编码失败")
        }

        return SnapResult(
            imageBase64: jpegData.base64EncodedString(),
            width: Int(resized.size.width),
            height: Int(resized.size.height),
            camera: facingValue ?? "back",
            format: format.rawValue
        )
    }

    // MARK: - Record Clip（camera.clip）

    static func clip(
        camera: String? = nil,
        facing: String? = nil,
        durationMs: Int? = nil,
        includeAudio: Bool? = nil,
        format: CameraVideoFormat = .mp4,
        deviceId: String? = nil
    ) async throws -> ClipResult {
        let facingValue = camera ?? facing
        let preferFront = facingValue == "front"
        let duration = clampDurationMs(durationMs)
        let includeAudio = includeAudio ?? true

        try await ensureAccess(for: .video)
        if includeAudio {
            try await ensureAccess(for: .audio)
        }

        let movURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawtalk-camera-\(UUID().uuidString).mov")
        let mp4URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawtalk-camera-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: movURL)
            try? FileManager.default.removeItem(at: mp4URL)
        }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = pickCamera(position: preferFront ? .front : .back, deviceId: deviceId) else {
            throw CameraError.unavailable("没有可用的摄像头")
        }
        do {
            try addInput(session: session, device: device)
        } catch {
            throw CameraError.unavailable("无法添加摄像头输入：\(error.localizedDescription)")
        }

        if includeAudio {
            guard let mic = AVCaptureDevice.default(for: .audio) else {
                throw CameraError.unavailable("没有可用的麦克风")
            }
            do {
                try addInput(session: session, device: mic)
            } catch {
                throw CameraError.unavailable("无法添加麦克风输入：\(error.localizedDescription)")
            }
        }

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            throw CameraError.unavailable("无法将录像输出添加到会话")
        }
        session.addOutput(output)
        output.maxRecordedDuration = CMTime(value: Int64(duration), timescale: 1000)

        session.startRunning()
        defer { session.stopRunning() }
        try await Task.sleep(nanoseconds: 150_000_000) // warmup

        let recording = CameraMovieRecordingOperation(output: output, outputURL: movURL)
        let recordedURL = try await recording.run()

        try await exportToMP4(inputURL: recordedURL, outputURL: mp4URL)
        let data = try Data(contentsOf: mp4URL)
        return ClipResult(
            format: format.rawValue,
            base64: data.base64EncodedString(),
            durationMs: duration,
            hasAudio: includeAudio
        )
    }

    // MARK: - Private helpers

    private static func addInput(session: AVCaptureSession, device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.captureFailed("无法添加输入")
        }
        session.addInput(input)
    }

    private static func ensureAccess(for mediaType: AVMediaType) async throws {
        let authorized: Bool = switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: mediaType)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
        if !authorized {
            throw CameraError.denied
        }
    }

    private static func pickCamera(position: AVCaptureDevice.Position, deviceId: String?) -> AVCaptureDevice? {
        if let deviceId, !deviceId.isEmpty {
            if let match = discoverySession().devices.first(where: { $0.uniqueID == deviceId }) {
                return match
            }
        }
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return device
        }
        return AVCaptureDevice.default(for: .video)
    }

    private static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera,
                .builtInLiDARDepthCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )
    }

    private static func positionLabel(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .front: return "front"
        case .back: return "back"
        default: return "unspecified"
        }
    }

    private static func clampDurationMs(
        _ ms: Int?,
        defaultMs: Int = 3000,
        minMs: Int = 250,
        maxMs: Int = 60000
    ) -> Int {
        let value = ms ?? defaultMs
        return min(maxMs, max(minMs, value))
    }

    private static func exportToMP4(inputURL: URL, outputURL: URL) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw CameraError.exportFailed("无法创建导出会话")
        }
        exporter.shouldOptimizeForNetworkUse = true
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                if let error = exporter.error {
                    continuation.resume(throwing: CameraError.exportFailed(error.localizedDescription))
                } else if exporter.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: CameraError.exportFailed("视频导出未完成（状态 \(exporter.status.rawValue)）")
                    )
                }
            }
        }
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
}

// MARK: - Photo Capture Delegate

private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private var continuation: CheckedContinuation<Data, Error>?

    func waitForCapture() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation?.resume(returning: data)
        } else {
            continuation?.resume(throwing: CameraCapability.CameraError.captureFailed("没有照片数据"))
        }
        continuation = nil
    }
}

// MARK: - Movie Recording Operation（camera.clip）

private final class CameraMovieRecordingOperation: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    typealias StartAction = (any AVCaptureFileOutputRecordingDelegate) -> Void
    typealias StopAction = () -> Void

    private enum Phase {
        case idle
        case starting
        case startRequested
        case recording
        case cancelling
        case cancelled
        case finished
    }

    private struct State {
        var phase = Phase.idle
        var continuation: CheckedContinuation<URL, Error>?
        var stopRequested = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let startAction: StartAction
    private let stopAction: StopAction

    convenience init(output: AVCaptureMovieFileOutput, outputURL: URL) {
        self.init(
            startAction: { delegate in
                output.startRecording(to: outputURL, recordingDelegate: delegate)
            },
            stopAction: { output.stopRecording() }
        )
    }

    init(startAction: @escaping StartAction, stopAction: @escaping StopAction) {
        self.startAction = startAction
        self.stopAction = stopAction
    }

    func run() async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.begin(continuation)
            }
        }, onCancel: {
            self.cancel()
        })
    }

    func cancel() {
        let shouldStop = self.state.withLock { state -> Bool in
            switch state.phase {
            case .idle:
                state.phase = .cancelled
                return false
            case .starting:
                state.phase = .cancelling
                return false
            case .startRequested, .recording:
                state.phase = .cancelling
                guard !state.stopRequested else { return false }
                state.stopRequested = true
                return true
            case .cancelling, .cancelled, .finished:
                return false
            }
        }
        if shouldStop {
            self.stopAction()
        }
    }

    func recordingDidStart() {
        self.state.withLock { state in
            switch state.phase {
            case .starting, .startRequested:
                state.phase = .recording
            case .cancelling:
                break
            case .idle, .recording, .cancelled, .finished:
                break
            }
        }
    }

    func recordingDidFinish(outputURL: URL, error: Error?) {
        let completion = self.state.withLock { state -> (CheckedContinuation<URL, Error>, Result<URL, Error>)? in
            guard let continuation = state.continuation else { return nil }

            let result: Result<URL, Error>
            switch state.phase {
            case .cancelling:
                result = .failure(CancellationError())
            case .starting, .startRequested, .recording:
                result = Self.recordingResult(outputURL: outputURL, error: error)
            case .idle, .cancelled, .finished:
                return nil
            }

            state.phase = .finished
            state.continuation = nil
            return (continuation, result)
        }
        if let (continuation, result) = completion {
            continuation.resume(with: result)
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        self.recordingDidStart()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        self.recordingDidFinish(outputURL: outputFileURL, error: error)
    }

    private func begin(_ continuation: CheckedContinuation<URL, Error>) {
        let shouldStart = self.state.withLock { state -> Bool in
            switch state.phase {
            case .idle:
                state.phase = .starting
                state.continuation = continuation
                return true
            case .cancelled:
                state.phase = .finished
                return false
            case .starting, .startRequested, .recording, .cancelling, .finished:
                preconditionFailure("相机录像操作只能运行一次")
            }
        }
        guard shouldStart else {
            continuation.resume(throwing: CancellationError())
            return
        }

        self.startAction(self)
        let shouldStop = self.state.withLock { state -> Bool in
            switch state.phase {
            case .starting:
                state.phase = .startRequested
                return false
            case .cancelling:
                guard !state.stopRequested else { return false }
                state.stopRequested = true
                return true
            case .idle, .startRequested, .recording, .cancelled, .finished:
                return false
            }
        }
        if shouldStop {
            self.stopAction()
        }
    }

    private static func recordingResult(outputURL: URL, error: Error?) -> Result<URL, Error> {
        guard let error else { return .success(outputURL) }
        let ns = error as NSError
        if ns.domain == AVFoundationErrorDomain,
           ns.code == AVError.maximumDurationReached.rawValue
        {
            return .success(outputURL)
        }
        return .failure(error)
    }
}

// MARK: - Params

struct CameraSnapParams: Decodable {
    let camera: String?
    let facing: String?
    let quality: Double?
    let maxWidth: Int?
    let format: String?
    let deviceId: String?
    let delayMs: Int?
}

struct CameraClipParams: Decodable {
    let camera: String?
    let facing: String?
    let durationMs: Int?
    let includeAudio: Bool?
    let format: String?
    let deviceId: String?
}
