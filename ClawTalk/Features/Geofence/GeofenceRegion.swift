import Foundation

/// 围栏地点类型：家 / 公司 / 自定义。
enum GeofenceType: String, Codable, CaseIterable, Identifiable, Equatable {
    case home = "home"
    case work = "work"
    case custom = "custom"

    var id: String { rawValue }

    /// 展示名称。
    var displayName: String {
        switch self {
        case .home: return "家"
        case .work: return "公司"
        case .custom: return "自定义"
        }
    }

    /// SF Symbol 图标（列表 / 表单用）。
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        case .custom: return "mappin.circle.fill"
        }
    }
}

/// 围栏触发事件：进入 / 离开 / 两者。
enum GeofenceEvent: String, Codable, CaseIterable, Identifiable, Equatable {
    case onEntry = "onEntry"
    case onExit = "onExit"
    case both = "both"

    var id: String { rawValue }

    /// 展示名称。
    var displayName: String {
        switch self {
        case .onEntry: return "进入时"
        case .onExit: return "离开时"
        case .both: return "进入和离开"
        }
    }

    /// 是否监听进入事件。
    var monitorsEntry: Bool { self == .onEntry || self == .both }

    /// 是否监听离开事件。
    var monitorsExit: Bool { self == .onExit || self == .both }
}

/// 一条地理围栏提醒（本地 UserDefaults 存储 + CLCircularRegion 注册共用）。
/// 进入 / 离开事件由系统级围栏监听投递（GeofenceStore 作为
/// CLLocationManagerDelegate 接收 didEnterRegion / didExitRegion），
/// 命中后发本地通知（title = 围栏名，body = message）。
struct GeofenceRegion: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var latitude: Double
    var longitude: Double
    /// 半径（米），默认 100；注册时按系统要求夹紧到 >= 1 米。
    var radius: Double
    var type: GeofenceType
    var event: GeofenceEvent
    /// 提醒文案（如「到家了，记得收快递」）；为空时通知用「已到达/已离开」兜底文案。
    var message: String
    /// 开关：关闭后停止监听该围栏（stopMonitoring）。
    var enabled: Bool
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        latitude: Double,
        longitude: Double,
        radius: Double = 100,
        type: GeofenceType,
        event: GeofenceEvent = .both,
        message: String = "",
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.type = type
        self.event = event
        self.message = message
        self.enabled = enabled
        self.createdAt = createdAt
    }

    /// 坐标展示文案。
    var coordinateText: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    /// 半径展示文案。
    var radiusText: String {
        radius >= 1000 ? String(format: "%.1f 公里", radius / 1000) : "\(Int(radius)) 米"
    }
}
