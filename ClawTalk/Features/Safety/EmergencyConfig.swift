import Foundation

/// 紧急求助配置模型（本地 JSON 持久化，见 EmergencyStore）。
///
/// 诚实标注：
/// - `autoCallEmergency` 仅作为配置记录，iOS 不允许 App 自动拨号
///   （110/120/任意号码均不可自动拨打）。触发链路不会自动拨号；
///   界面只提供「打开拨号盘」按钮（tel:// 只能跳到系统拨号界面，需用户手动确认拨打）。
/// - 电源键连按 5 次触发在 iOS 无公开 API，未实现；用主页 SOS 按钮 +
///   锁屏小组件/深链（clawtalk://sos）代替，见 EmergencyStore。
struct EmergencyConfig: Codable, Equatable {
    /// 总开关（关闭时主页 SOS 按钮拒绝触发并提示）
    var enabled: Bool
    /// 预设紧急联系人：电话号码（如 "+86 13812345678"）或网关频道名
    /// （须与 ClawTalk 频道列表 ChannelStore 中的频道名一致）。
    /// - 电话联系人：网关没有电话/短信通道，触发时诚实标「未发送」，提供手动拨号入口。
    /// - 频道联系人：触发时通过网关 chat.send 发送到该频道会话。
    var emergencyContacts: [String]
    /// 求助文案（取不到位置或未开启位置时使用）。
    /// 开启位置且取到位置时，触发链路会用固定模板
    /// 「紧急求助：我在[地址/坐标]，请尽快联系我。」拼装。
    var sosMessage: String
    /// 诚实标注：iOS 无自动拨号 API。true = 触发时界面提示手动拨号；不会自动拨打。
    var autoCallEmergency: Bool?
    /// 是否在求助信息中附带位置（需要定位权限；取不到位置时诚实降级为纯文案）
    var includeLocation: Bool
    /// 配置创建时间
    var createdAt: Date
    /// 配置最后修改时间（编辑保存时刷新）
    var updatedAt: Date

    static let `default` = EmergencyConfig(
        enabled: false,
        emergencyContacts: [],
        sosMessage: "紧急求助，请尽快联系我！",
        autoCallEmergency: nil,
        includeLocation: true,
        createdAt: Date()
    )

    init(
        enabled: Bool,
        emergencyContacts: [String],
        sosMessage: String,
        autoCallEmergency: Bool?,
        includeLocation: Bool,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.enabled = enabled
        self.emergencyContacts = emergencyContacts
        self.sosMessage = sosMessage
        self.autoCallEmergency = autoCallEmergency
        self.includeLocation = includeLocation
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// 兼容旧数据：缺失字段回退默认值，不破坏已有存档。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        emergencyContacts = try container.decodeIfPresent([String].self, forKey: .emergencyContacts) ?? []
        sosMessage = try container.decodeIfPresent(String.self, forKey: .sosMessage)
            ?? "紧急求助，请尽快联系我！"
        autoCallEmergency = try container.decodeIfPresent(Bool.self, forKey: .autoCallEmergency)
        includeLocation = try container.decodeIfPresent(Bool.self, forKey: .includeLocation) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// 判断联系人类型：长得像电话号码 → 电话联系人；否则视为网关频道名。
    static func kind(of raw: String) -> EmergencyContactKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = " +-()"
        let looksLikePhone = trimmed.allSatisfy { $0.isNumber || allowedCharacters.contains($0) }
            && trimmed.filter(\.isNumber).count >= 5
        return looksLikePhone ? .phone(trimmed) : .gatewayChannel(trimmed)
    }
}

/// 紧急联系人类型（电话 或 网关频道名）。
enum EmergencyContactKind: Equatable {
    case phone(String)
    case gatewayChannel(String)

    var icon: String {
        switch self {
        case .phone: return "phone.fill"
        case .gatewayChannel: return "bubble.left.and.bubble.right.fill"
        }
    }

    var typeLabel: String {
        switch self {
        case .phone: return "电话"
        case .gatewayChannel: return "频道"
        }
    }
}
