import Foundation
import Observation

/// 官方 Talk 模式状态机（对齐 TalkModeManager 的 ActivePushToTalk/FinishingPushToTalk）：
/// 经网关 talk.client.create 建立实时会话，路由 Realtime 事件；网关不支持时由调用方降级本地 PTT。
@MainActor
@Observable
final class TalkModeManager {
    enum State: Equatable {
        case idle
        case connecting
        case active
        case finishing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var sessionKey: String?
    private(set) var voiceSessionId: String?
    private(set) var lastTranscript: String = ""
    private(set) var lastEventType: String?
    private(set) var supportsRealtime = false

    private var gatewayConnection: GatewayConnection?

    func attach(gatewayConnection: GatewayConnection) {
        self.gatewayConnection = gatewayConnection
    }

    /// 开始 Talk：探测网关能力 → talk.client.create → active。失败抛错由调用方降级。
    func beginTalk() async throws {
        guard let gatewayConnection else {
            state = .failed("未连接网关")
            throw TalkModeError.notConnected
        }
        let supported = await gatewayConnection.supportsServerMethod("talk.client.create") ?? false
        supportsRealtime = supported
        guard supported else {
            state = .idle
            throw TalkModeError.unsupported
        }
        state = .connecting
        do {
            let response = try await gatewayConnection.talkClientCreate(
                TalkRealtimeClientCreateParams(transport: "realtime")
            )
            guard response.ok != false else {
                state = .failed(response.error ?? "网关拒绝实时会话")
                throw TalkModeError.rejected(response.error)
            }
            sessionKey = response.sessionKey
            voiceSessionId = response.voiceSessionId
            lastTranscript = ""
            state = .active
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 结束 Talk：talk.client.close → idle。
    func endTalk() async {
        guard state == .active || state == .connecting else {
            state = .idle
            return
        }
        state = .finishing
        if let gatewayConnection {
            do {
                _ = try await gatewayConnection.talkClientClose(
                    TalkRealtimeClientCloseParams(sessionKey: sessionKey, voiceSessionId: voiceSessionId)
                )
            } catch {
                // 关闭失败不阻断状态复位
            }
        }
        sessionKey = nil
        voiceSessionId = nil
        state = .idle
    }

    /// 网关推送的 talk 事件路由（Realtime 事件 → 状态/转写）。
    func handleGatewayEvent(_ event: TalkRealtimeEvent) {
        lastEventType = event.type
        if let delta = event.delta, !delta.isEmpty {
            lastTranscript += delta
        }
        switch event.eventType {
        case .inputAudioBufferSpeechStarted:
            if state == .active { state = .active }
        case .responseDone, .conversationItemDone:
            break
        case .error:
            state = .failed(event.error ?? "实时语音错误")
        default:
            break
        }
    }

    func reset() {
        state = .idle
        sessionKey = nil
        voiceSessionId = nil
        lastTranscript = ""
        lastEventType = nil
    }

    enum TalkModeError: LocalizedError {
        case notConnected
        case unsupported
        case rejected(String?)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "未连接网关"
            case .unsupported: return "网关不支持实时语音（已降级本地模式）"
            case .rejected(let message): return message ?? "网关拒绝实时会话"
            }
        }
    }
}