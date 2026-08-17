import Foundation

/// 网关 Operator 舰队管理（对齐官方 GatewayOperatorFleet）：
/// operator.read / operator.write / operator.talk.secrets —— 管理多 operator 设备会话。
struct GatewayOperatorFleet {
    /// operator.read → 当前 operator 会话/设备列表
    struct OperatorReadParams: Encodable {
        var includeTalkSecrets: Bool? = nil
    }

    struct OperatorSessionInfo: Codable, Identifiable {
        var id: String? { deviceId }
        var deviceId: String?
        var role: String?
        var connected: Bool?
        var lastSeenMs: Double?
        var displayName: String?
        var kind: String?
        var talkToken: String?
        var talkUrl: String?
    }

    struct OperatorListResponse: Codable {
        var operators: [OperatorSessionInfo]?
        var count: Int?
    }

    /// operator.write → 更新 operator 设备（如改名）
    struct OperatorWriteParams: Encodable {
        var deviceId: String
        var displayName: String? = nil
    }

    /// operator.talk.secrets → 获取某 operator 的语音凭据（Talk 模式用）
    struct OperatorTalkSecretsParams: Encodable {
        var deviceId: String
    }
}