import Foundation

/// 聊天对象（联系人档案），来自 OpenClaw 网关 GET /contacts。
/// - id: 联系人唯一标识（档案 ID）
/// - name: 显示名（昵称）
/// - profileScore: 画像完整度 0.0~1.0（记忆条数/多样性估算，用于键盘显示"画像完整度"与分层策略）
struct ChatContact: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let profileScore: Double
}