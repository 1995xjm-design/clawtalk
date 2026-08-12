import Foundation

/// 出行清单项：文本 + 完成状态。
struct TravelChecklistItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var done: Bool

    init(id: UUID = UUID(), text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }
}

/// 出行状态分组（列表页分区用）。
enum TravelTripStatus: String, Codable, Equatable {
    case ongoing
    case upcoming
    case history

    var sectionTitle: String {
        switch self {
        case .ongoing: return "进行中"
        case .upcoming: return "即将出发"
        case .history: return "历史出行"
        }
    }
}

/// 一次出行（差旅/旅行）。本地 UserDefaults 存储，数据只保存在本机。
struct TravelTrip: Identifiable, Codable, Equatable {
    let id: UUID
    var destination: String
    var departureDate: Date
    var returnDate: Date?
    var purpose: String?
    var checklist: [TravelChecklistItem]
    /// 航班信息（自由文本，暂不解析）
    var flights: [String]?
    /// 酒店信息（自由文本，暂不解析）
    var hotels: [String]?
    var notes: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        destination: String,
        departureDate: Date,
        returnDate: Date? = nil,
        purpose: String? = nil,
        checklist: [TravelChecklistItem] = [],
        flights: [String]? = nil,
        hotels: [String]? = nil,
        notes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.destination = destination
        self.departureDate = departureDate
        self.returnDate = returnDate
        self.purpose = purpose
        self.checklist = checklist
        self.flights = flights
        self.hotels = hotels
        self.notes = notes
        self.createdAt = createdAt
    }

    /// 行程结束时刻：有返程 → 返程日次日 00:00；无返程 → 按出发日算。
    var periodEndDate: Date {
        guard let returnDate else { return departureDate }
        return Calendar.current.date(byAdding: .day, value: 1, to: returnDate) ?? returnDate
    }

    /// 距离出发剩余天数：未来为正、当天为 0、已出发为负。
    var daysUntilDeparture: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let departure = calendar.startOfDay(for: departureDate)
        return calendar.dateComponents([.day], from: today, to: departure).day ?? 0
    }

    /// 分组状态：返程已过 → 历史；还没出发 → 即将出发；其余（含无返程已出发）→ 进行中。
    var travelStatus: TravelTripStatus {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let returnDate, calendar.startOfDay(for: returnDate) < today {
            return .history
        }
        if calendar.startOfDay(for: departureDate) > today {
            return .upcoming
        }
        return .ongoing
    }
}
