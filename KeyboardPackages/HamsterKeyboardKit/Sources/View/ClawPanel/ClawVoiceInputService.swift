import AVFoundation
import Foundation
import HamsterKit
import Speech

/// 语音输入服务：按住说话 → SFSpeechRecognizer（zh-Hans）转文字
public final class ClawVoiceInputService: NSObject {
  public static let shared = ClawVoiceInputService()

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))
  private var audioEngine: AVAudioEngine?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?

  /// 是否正在录音
  public private(set) var isRecording = false

  private override init() {
    super.init()
  }

  /// 请求麦克风 + 语音识别权限
  public func requestAuthorization(completion: @escaping (Bool) -> Void) {
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard let self else {
        completion(false)
        return
      }
      guard status == .authorized else {
        ClawLog.record(module: "键盘语音", "语音识别权限未授权（状态 \(status.rawValue)）")
        completion(false)
        return
      }
      let session = AVAudioSession.sharedInstance()
      switch session.recordPermission {
      case .granted:
        completion(true)
      case .denied:
        ClawLog.record(module: "键盘语音", "麦克风权限未授权")
        completion(false)
      default:
        session.requestRecordPermission { granted in
          DispatchQueue.main.async {
            completion(granted)
          }
        }
      }
    }
  }

  /// 开始录音；停止后通过 completion 返回最终识别文本
  public func start(completion: @escaping (Result<String, Error>) -> Void) {
    stop()
    guard let recognizer, recognizer.isAvailable else {
      ClawLog.record(module: "键盘语音", "语音识别器不可用")
      completion(.failure(ClawVoiceError.recognizerUnavailable))
      return
    }

    let audioEngine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = false
    request.requiresOnDeviceRecognition = false

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
      ClawLog.record(module: "键盘语音", "麦克风输入格式无效")
      completion(.failure(ClawVoiceError.audioUnavailable))
      return
    }
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      ClawLog.record(module: "键盘语音", "录音启动失败：\(error.localizedDescription)")
      completion(.failure(error))
      return
    }

    self.audioEngine = audioEngine
    self.recognitionRequest = request
    isRecording = true

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let result, result.isFinal {
        self.cleanup()
        completion(.success(result.bestTranscription.formattedString))
      } else if error != nil {
        self.cleanup()
        ClawLog.record(module: "键盘语音", "语音识别失败：\(error?.localizedDescription ?? ClawVoiceError.unknown.localizedDescription)")
        completion(.failure(error ?? ClawVoiceError.unknown))
      }
    }
  }

  /// 停止录音，触发最终识别回调
  public func stop() {
    guard isRecording else { return }
    recognitionRequest?.endAudio()
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    audioEngine = nil
    recognitionRequest = nil
    isRecording = false
  }

  private func cleanup() {
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine = nil
    recognitionRequest = nil
    recognitionTask = nil
    isRecording = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

public enum ClawVoiceError: LocalizedError {
  case recognizerUnavailable
  case audioUnavailable
  case unknown

  public var errorDescription: String? {
    switch self {
    case .recognizerUnavailable: return "语音识别不可用，请检查系统设置"
    case .audioUnavailable: return "麦克风不可用"
    case .unknown: return "语音识别失败"
    }
  }
}
