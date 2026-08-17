import Foundation

/// 网关连接状态展示模型（官方对齐 GatewayDisplayState）。
enum GatewayDisplayState: Equatable {
    case connected
    case connecting
    case error
    case disconnected
}

enum GatewayStatusBuilder {
    /// 由我方 GatewayConnection 可观察状态构建展示状态（等价官方 NodeAppModel 适配）。
    @MainActor
    static func build(connection: GatewayConnection) -> GatewayDisplayState {
        build(
            connectionState: connection.connectionState,
            lastError: connection.lastError)
    }

    static func build(
        connectionState: GatewayConnection.State,
        lastError: String?) -> GatewayDisplayState
    {
        switch connectionState {
        case .connected:
            return .connected
        case .connecting:
            return .connecting
        case .disconnected:
            let text = (lastError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return .error
            }
            return .disconnected
        }
    }
}
