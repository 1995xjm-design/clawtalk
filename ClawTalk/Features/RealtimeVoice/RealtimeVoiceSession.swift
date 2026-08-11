import Foundation
import Observation

/// 实时语音传输模式。
enum RealtimeVoiceTransportMode: Equatable, Sendable {
    /// 半双工对讲（当前实现）：按住说话 → STT → 发送 → 回复 → TTS 播放。
    /// 诚实标注：OpenClaw 网关 WebRTC 信令端点未确认，工程也未集成 WebRTC 音频栈，
    /// 因此不冒充全双工通话。
    case halfDuplex
    /// 预留：网关确认 WebRTC 信令端点并接入 WebRTC 库后启用全双工。
    case webRTC

    var displayName: String {
        switch self {
        case .halfDuplex: return "半双工对讲"
        case .webRTC: return "WebRTC 实时语音"
        }
    }
}

/// 实时语音会话状态（由 ChatViewModel 状态映射，不重复维护录音/转写状态机）。
enum RealtimeVoiceState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case waitingReply
    case speaking
}

/// 实时语音通话会话（WebRTC 信令端点未确认 → 半双工对讲降级方案）。
///
/// 复用现有链路：按住说话（ChatViewModel.startRecording）→ STT 转写 →
/// 发送（ChatViewModel.stopRecordingAndSend / sendMessage）→ 回复 → TTS 朗读
/// （ChatViewModel 自带语音输出管线）。本类只做会话编排、传输模式探测与唤醒仲裁，
/// 不重复实现录音/转写/发送/TTS。
@Observable
@MainActor
final class RealtimeVoiceSession {

    // MARK: - 传输模式（诚实标注）

    private(set) var transportMode: RealtimeVoiceTransportMode = .halfDuplex
    /// 网关是否存在可响应的 WebRTC 信令端点（探测结论，默认未确认）。
    private(set) var signalingEndpointConfirmed = false
    /// 探测/降级说明（UI 展示，诚实标注）。
    private(set) var probeNote = "WebRTC 信令端点未确认，当前为半双工对讲（按住说话）"

    // MARK: - 会话状态

    private(set) var isSessionActive = false
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "实时语音", errorMessage)
            }
        }
    }

    // MARK: - 依赖（复用现有链路）

    let chatViewModel: ChatViewModel
    private let gatewayConnection: GatewayConnection?

    init(chatViewModel: ChatViewModel, gatewayConnection: GatewayConnection? = nil) {
        self.chatViewModel = chatViewModel
        self.gatewayConnection = gatewayConnection
    }

    // MARK: - 状态映射

    var state: RealtimeVoiceState {
        switch chatViewModel.state {
        case .idle: return .idle
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .thinking, .streaming: return .waitingReply
        case .speaking: return .speaking
        }
    }

    var audioLevel: Float {
        chatViewModel.audioLevel
    }

    var statusText: String {
        switch state {
        case .idle: return "按住下方按钮说话"
        case .recording: return "正在聆听…松开发送"
        case .transcribing: return "正在转写…"
        case .waitingReply: return "等待回复…"
        case .speaking: return "正在朗读回复…"
        }
    }

    // MARK: - 会话生命周期

    /// 进入对讲页：经唤醒仲裁器占用麦克风，暂停唤醒词监听，并后台尽力探测信令端点。
    func startSession() {
        guard !isSessionActive else { return }
        isSessionActive = true
        errorMessage = nil
        // 手动对讲占用麦克风：仲裁器拒绝一切唤醒源抢麦
        _ = VoiceWakeArbiter.shared.holdIntercom()
        VoiceWakeCapability.shared.stopListening()
        Task { await probeSignalingEndpoint() }
    }

    /// 退出对讲页：停止本地录音/朗读；在途回复不取消（与聊天页退出一致，由 App 层收尾）。
    func stopSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        if state == .recording || state == .transcribing {
            chatViewModel.stop()
        } else {
            chatViewModel.stopSpeaking()
        }
        VoiceWakeArbiter.shared.releaseIntercom()
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }

    // MARK: - 对讲（半双工：按住说话）

    func beginTalk() {
        chatViewModel.startRecording()
    }

    func endTalk() {
        chatViewModel.stopRecordingAndSend()
    }

    // MARK: - WebRTC 信令端点探测

    /// 尽力探测网关是否有 WebRTC 信令端点。
    /// 候选方法名（webrtc.* / realtime.*）为工程侧约定，OpenClaw 网关是否实现未确认：
    /// 任一候选能正常响应即视为存在端点；全部失败则维持「未确认」。
    /// 无论结果如何，当前都以半双工运行——工程未集成 WebRTC 音频栈。
    private func probeSignalingEndpoint() async {
        guard let gateway = gatewayConnection, gateway.connectionState == .connected else {
            probeNote = "网关未连接，未探测 WebRTC 信令端点；当前为半双工对讲"
            return
        }

        let candidates = ["webrtc.signal", "realtime.voice.signal"]
        for method in candidates {
            do {
                _ = try await gateway.request(method: method, params: ["action": AnyCodable("probe")])
                signalingEndpointConfirmed = true
                probeNote = "网关可响应 \(method)，但工程未集成 WebRTC 音频栈，仍以半双工运行"
                return
            } catch {
                continue
            }
        }

        signalingEndpointConfirmed = false
        probeNote = "未探测到可用的 WebRTC 信令端点，当前为半双工对讲（按住说话）"
    }
}
