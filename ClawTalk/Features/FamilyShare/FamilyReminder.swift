import Foundation

/// 家庭共享提醒状态：待确认 / 已确认 / 已完成。
enum FamilyReminderStatus: String, Codable, CaseIterable, Identifiable, Equatable {
    case pending = "pending"
    case confirmed = "confirmed"
    case completed = "completed"

    var id: String { rawValue }

    /// 展示用名称。
    var displayName: String {
        switch self {
        case .pending: return "待确认"
        case .confirmed: return "已确认"
        case .completed: return "已完成"
        }
    }
}

/// 共享提醒方向：我共享给家人 / 家人共享给我。
enum FamilyReminderDirection: String, Codable, CaseIterable, Identifiable, Equatable {
    case sent = "sent"
    case received = "received"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sent: return "我共享的"
        case .received: return "家人发来的"
        }
    }
}

/// 一条家庭共享提醒（本地 App Group 持久化 + 网关共享共用）。
///
/// 字段说明：
/// - status：待确认 → 已确认 → 已完成；家人端确认后由网关回写（回写端点待网关侧确认）
/// - direction：sent = 我共享给家人；received = 家人共享给我
/// - synced：true = 已通过网关送达家人；false = 未同步（网关未配置/失败，本地先保留）
struct FamilyReminder: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    /// 提醒时间（由 CareReminder 转来时取 scheduledDate ?? time，保留一次性提醒的完整日期）。
    var time: Date
    /// 负责人（谁负责执行；共享给家人时填家人称呼）。
    var assignee: String
    var status: FamilyReminderStatus
    var direction: FamilyReminderDirection
    /// 共享发生的时间（发给家人 / 收到家人提醒的时间）。
    let sharedAt: Date
    let createdAt: Date
    /// 网关同步状态：synced=false 时列表展示「未同步」并提供重试。
    var synced: Bool

    init(
        id: String = UUID().uuidString,
        title: String,
        time: Date = Date(),
        assignee: String,
        status: FamilyReminderStatus = .pending,
        direction: FamilyReminderDirection = .sent,
        sharedAt: Date = Date(),
        createdAt: Date = Date(),
        synced: Bool = false
    ) {
        self.id = id
        self.title = title
        self.time = time
        self.assignee = assignee
        self.status = status
        self.direction = direction
        self.sharedAt = sharedAt
        self.createdAt = createdAt
        self.synced = synced
    }
}
