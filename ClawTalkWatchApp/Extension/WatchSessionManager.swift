import Combine
import Foundation
import WatchConnectivity

// MARK: - iPhone 主 App 接线契约（TODO：由主智能体在 ClawTalk/ 主 App 侧完成）
//
// 手表 <-> iPhone 只通过 WatchConnectivity（WCSession）通信，手表不直接调网关
// （网关 token 在 iPhone Keychain，手表侧拿不到）。
//
// 1) iPhone 侧接线位置：ClawTalk/App/AppDelegate.swift 或 ClawTalkApp.swift 的
//    启动流程里持有 WCSession：
//        WCSession.default.delegate = <WCSessionDelegate 实现>
//        WCSession.default.activate()
//    注意 iPhone 侧 WCSessionDelegate 必须实现：
//        session(_:activationDidCompleteWith:error:)
//        sessionDidBecomeInactive(_:)
//        sessionDidDeactivate(_:)
//
// 2) iPhone 侧收到的请求（message["kind"]）与应回复的格式：
//    - "sendText"：payload { kind, text, sentAt, channelName? }
//      按 channelName 找频道（找不到用默认频道），聊天页开着走
//      ChatViewModel.sendText，否则走网关 WebSocket/HTTP（参考
//      ClawTalkApp.sendShareMessage）。回复 { "ok": Bool, "message": String? }
//    - "wake"：payload { kind, channelName? }
//      触发与语音唤醒相同的「进入对话」流程（参考
//      ClawTalkApp.handleWakeWordDetected）。回复 { "ok": Bool, "message": String? }
//    - "requestMessages"：payload { kind, channelName? }
//      用 ConversationStore 读该频道最近 N 条消息（建议 30 条），回复
//      { "kind": "messages", "channelName": "...", "messages": [WatchMessage JSON] }
//    - "requestChannels"：payload { kind }
//      回复 { "kind": "channels", "channels": [WatchChannel JSON] }
//
// 3) iPhone -> watch 主动推送（新消息/频道变化时）：
//    { "kind": "messages", "channelName": "...", "messages": [...] }
//    { "kind": "channels", "channels": [...] }
//    iPhone App 运行中可用 sendMessage；App 未运行时用 transferUserInfo 排队，
//    watch 侧在 session(_:didReceiveUserInfo:) 里接收（本文件已处理）。
//
// 4) 编解码约定：JSONEncoder/JSONDecoder 默认策略；payload 必须只含
//    String/Number/Bool/数组/字典（WCSession 要求 property-list 类型），
//    先 JSON 编码成 [String: Any] 再发送，禁止直接塞 UUID/Data/Date。

/// 手表端 WatchConnectivity 管理器：与 iPhone 主 App 交换频道列表与消息，
/// 语音文本经 sendText 转发给 iPhone 由主 App 走网关。
final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    @Published private(set) var messages: [WatchMessage] = []
    @Published private(set) var channels: [WatchChannel] = []
    @Published private(set) var isActivated = false
    @Published private(set) var isReachable = false
    @Published private(set) var statusText = "WCSession 未激活"

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            statusText = "此设备不支持 WatchConnectivity"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isActivated = activationState == .activated
            self.isReachable = session.isReachable
            self.updateStatusText()
        }
    }


    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.updateStatusText()
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleIncoming(message)
        replyHandler(["kind": "ack"])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleIncoming(userInfo)
    }

    // MARK: - Incoming（iPhone -> watch）

    private func handleIncoming(_ payload: [String: Any]) {
        guard let kind = payload["kind"] as? String else { return }
        DispatchQueue.main.async {
            switch kind {
            case "messages":
                guard let channelName = payload["channelName"] as? String,
                      let list = payload["messages"] as? [[String: Any]] else { return }
                self.messages = list.compactMap { Self.decode(WatchMessage.self, from: $0) }
                self.statusText = "已更新：\(channelName)"
            case "channels":
                guard let list = payload["channels"] as? [[String: Any]] else { return }
                self.channels = list.compactMap { Self.decode(WatchChannel.self, from: $0) }
            default:
                break
            }
        }
    }

    // MARK: - Outgoing（watch -> iPhone）

    /// 语音/文本发送：转发给 iPhone 主 App，由主 App 走网关（OpenClaw 智能体）。
    func sendText(_ text: String, channelName: String?) {
        var payload: [String: Any] = [
            "kind": "sendText",
            "text": text,
            "sentAt": Date().timeIntervalSince1970
        ]
        if let channelName {
            payload["channelName"] = channelName
        }
        sendRequest(payload)
    }

    /// 快捷唤醒智能体：让 iPhone 侧进入对话（主智能体按 handleWakeWordDetected 接线）。
    func wakeAgent(channelName: String?) {
        var payload: [String: Any] = ["kind": "wake"]
        if let channelName {
            payload["channelName"] = channelName
        }
        sendRequest(payload)
    }

    func requestMessages(channelName: String?) {
        var payload: [String: Any] = ["kind": "requestMessages"]
        if let channelName {
            payload["channelName"] = channelName
        }
        sendRequest(payload)
    }

    func requestChannels() {
        sendRequest(["kind": "requestChannels"])
    }

    private func sendRequest(_ payload: [String: Any]) {
        guard isActivated else {
            statusText = "WCSession 未激活"
            return
        }
        guard WCSession.default.isReachable else {
            // iPhone App 未运行/不可达：用队列消息，iPhone 下次激活时收到。
            WCSession.default.transferUserInfo(payload)
            statusText = "iPhone 暂不可达，已排队发送"
            return
        }
        WCSession.default.sendMessage(payload, replyHandler: { reply in
            DispatchQueue.main.async {
                self.handleReply(reply)
            }
        }, errorHandler: { error in
            DispatchQueue.main.async {
                self.statusText = "发送失败：\(error.localizedDescription)"
            }
        })
    }

    private func handleReply(_ reply: [String: Any]) {
        guard let kind = reply["kind"] as? String else {
            let ok = (reply["ok"] as? Bool) ?? false
            let message = (reply["message"] as? String) ?? (ok ? "已发送" : "发送失败")
            statusText = ok ? "已发送" : message
            return
        }
        switch kind {
        case "messages", "channels":
            handleIncoming(reply)
        default:
            let ok = (reply["ok"] as? Bool) ?? false
            statusText = ok ? "已发送" : ((reply["message"] as? String) ?? "发送失败")
        }
    }

    // MARK: - 编解码辅助

    private static func decode<T: Decodable>(_ type: T.Type, from dict: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func updateStatusText() {
        if !isActivated {
            statusText = "WCSession 未激活"
        } else if isReachable {
            statusText = "已连接 iPhone"
        } else {
            statusText = "iPhone 未连接（打开 ClawTalk 后可恢复）"
        }
    }
}