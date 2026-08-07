import Foundation
import AVFoundation
import Speech

// MARK: - 语音输入服务（按住说话 → 转文字）
/// 键盘扩展内语音输入：AVAudioEngine 录音 + 系统 SFSpeechRecognizer（zh-CN）识别。
/// 权限流程完整：先麦克风权限（AVAudioApplication），再语音识别权限（SFSpeechRecognizer），
/// 无权限/失败时通过 delegate 抛出中文提示，不崩溃。
final class VoiceInputService: NSObject {

    enum State {
        case idle
        case recording
        case transcribing
    }

    weak var delegate: VoiceInputServiceDelegate?

    private var recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var isRecording = false
    private var isAuthorizationPending = false
    private var isCancelling = false
    private var recordingStartDate: Date?

    /// 最短录音时长，防止误触
    private let minRecordingDuration: TimeInterval = 0.3

    override init() {
        super.init()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }

    // MARK: - 公共方法

    /// 按下开始录音（内部先走权限流程）
    func start() {
        guard !isRecording, !isAuthorizationPending else { return }
        requestMicrophonePermissionIfNeeded()
    }

    /// 松开结束录音并识别
    func finish() {
        guard isRecording else { return }

        let duration = Date().timeIntervalSince(recordingStartDate ?? Date())
        guard duration >= minRecordingDuration else {
            cancel()
            delegate?.voiceInputDidFail("说话时间太短，请按住再说")
            return
        }

        isRecording = false
        recordingStartDate = nil
        delegate?.voiceInputDidChangeState(.transcribing)

        stopAudioEngine()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    /// 取消（拖出/系统打断），不识别。isCancelling 保持 true，
    /// 防止旧识别任务的迟到回调污染后续会话。
    func cancel() {
        guard isRecording || isAuthorizationPending || recognitionTask != nil else {
            isCancelling = false
            return
        }
        isCancelling = true
        stopAudioEngine()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        isAuthorizationPending = false
        recordingStartDate = nil
        delegate?.voiceInputDidChangeState(.idle)
    }

    // MARK: - 权限流程

    private func requestMicrophonePermissionIfNeeded() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            requestSpeechAuthorizationIfNeeded()
        case .denied:
            delegate?.voiceInputDidFail("麦克风权限被拒绝，请在系统设置中允许键盘使用麦克风")
        case .undetermined:
            isAuthorizationPending = true
            AVAudioApplication.shared.requestRecordPermission { [weak self] granted in
                guard let self else { return }
                self.isAuthorizationPending = false
                DispatchQueue.main.async {
                    if granted {
                        self.requestSpeechAuthorizationIfNeeded()
                    } else {
                        self.delegate?.voiceInputDidFail("麦克风权限被拒绝，请在系统设置中允许键盘使用麦克风")
                    }
                }
            }
        @unknown default:
            delegate?.voiceInputDidFail("麦克风权限不可用")
        }
    }

    private func requestSpeechAuthorizationIfNeeded() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            startAudioEngine()
        case .notDetermined:
            isAuthorizationPending = true
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                guard let self else { return }
                self.isAuthorizationPending = false
                DispatchQueue.main.async {
                    switch status {
                    case .authorized:
                        self.startAudioEngine()
                    case .denied:
                        self.delegate?.voiceInputDidFail("语音识别权限被拒绝，请在系统设置中允许")
                    case .restricted:
                        self.delegate?.voiceInputDidFail("语音识别受设备限制，暂不可用")
                    default:
                        self.delegate?.voiceInputDidFail("语音识别权限不可用")
                    }
                }
            }
        case .denied:
            delegate?.voiceInputDidFail("语音识别权限被拒绝，请在系统设置中允许")
        case .restricted:
            delegate?.voiceInputDidFail("语音识别受设备限制，暂不可用")
        @unknown default:
            delegate?.voiceInputDidFail("语音识别权限不可用")
        }
    }

    // MARK: - 录音与识别

    private func startAudioEngine() {
        // 打断上一次未完成/迟到的识别，开启全新会话
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isCancelling = false

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setPreferredSampleRate(16000)
            try audioSession.setActive(true)
        } catch {
            delegate?.voiceInputDidFail("无法启动录音，请重试")
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            delegate?.voiceInputDidFail("语音识别不可用，请稍后重试")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            removeTap()
            recognitionRequest = nil
            delegate?.voiceInputDidFail("无法启动录音，请重试")
            return
        }

        startRecognitionTask(with: request)
        isRecording = true
        recordingStartDate = Date()
        delegate?.voiceInputDidChangeState(.recording)
    }

    private func startRecognitionTask(with request: SFSpeechAudioBufferRecognitionRequest) {
        let task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // 用户主动取消，或已开启新会话时忽略旧回调
            if self.isCancelling { return }
            if let currentTask = self.recognitionTask, currentTask !== task { return }

            if let result, result.isFinal {
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.cleanupRecognition()
                if !text.isEmpty {
                    self.delegate?.voiceInputDidProduceText(text)
                } else {
                    self.delegate?.voiceInputDidFail("没有听清，请再试一次")
                }
            } else if error != nil {
                self.cleanupRecognition()
                self.delegate?.voiceInputDidFail("语音识别失败，请重试")
            }
        }
        recognitionTask = task
    }

    private func stopAudioEngine() {
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        removeTap()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func removeTap() {
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func cleanupRecognition() {
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        recordingStartDate = nil
        delegate?.voiceInputDidChangeState(.idle)
    }
}

// MARK: - 语音输入代理
protocol VoiceInputServiceDelegate: AnyObject {
    func voiceInputDidChangeState(_ state: VoiceInputService.State)
    func voiceInputDidProduceText(_ text: String)
    func voiceInputDidFail(_ message: String)
}
