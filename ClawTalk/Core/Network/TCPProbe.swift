import Foundation
import Network

/// TCP 端口连通性探测（Network.framework，短超时）。
///
/// 对应官方 `apps/ios/Sources/Gateway/TCPProbe.swift` 的 `TCPProbe.probe(host:port:timeoutSeconds:queueLabel:)`：
/// 用 `NWConnection(.tcp)` 连接 host:port，状态 `.ready` 即成功，失败/超时即失败。
/// 宿主原先在 GatewayAutoDiscovery 与 ConnectionDiagnostics 中各有一份重复实现，统一收敛到这里，
/// 供网关发现、连接健康监控、一键诊断共用。
enum TCPProbe {
    static func probe(host: String, port: Int, timeoutSeconds: TimeInterval, queueLabel: String) async -> Bool {
        guard port >= 1, port <= 65535 else { return false }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            var didResume = false
            let lock = NSLock()
            func resumeOnce(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(true)
                case .failed, .cancelled:
                    resumeOnce(false)
                default:
                    break
                }
            }
            let queue = DispatchQueue(label: queueLabel)
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                resumeOnce(false)
            }
        }
    }
}
