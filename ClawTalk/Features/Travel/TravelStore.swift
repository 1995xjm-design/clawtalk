import Foundation
import Observation

/// 差旅管家存储：出行本地存储（UserDefaults JSON）+ 默认清单预置 + 出发提醒排期 + 语音解析。
@Observable
@MainActor
final class TravelStore {

    private(set) var trips: [TravelTrip] = []
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "差旅管家", errorMessage)
            }
        }
    }

    private let storageKey = "clawtalk_travel_trips_v1"
    private let reminderIDsKey = "clawtalk_travel_reminder_ids_v1"
    /// trip.id.uuidString → 已创建的 CareReminder id（顺序对应两个提醒槽位，防重复排）
    private var reminderIDsByTrip: [String: [String]] = [:]

    init() {
        load()
        loadReminderIDs()
    }

    // MARK: - 出行增删改查

    func trip(id: UUID) -> TravelTrip? {
        trips.first { $0.id == id }
    }

    @discardableResult
    func add(_ trip: TravelTrip) -> TravelTrip {
        trips.append(trip)
        sortTrips()
        persist()
        return trip
    }

    func update(_ trip: TravelTrip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index] = trip
        sortTrips()
        persist()
    }

    func delete(id: UUID) {
        trips.removeAll { $0.id == id }
        reminderIDsByTrip.removeValue(forKey: id.uuidString)
        persist()
        persistReminderIDs()
    }

    /// 勾选/取消勾选清单项。
    func toggleChecklistItem(tripID: UUID, itemID: UUID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        guard let itemIndex = trips[index].checklist.firstIndex(where: { $0.id == itemID }) else { return }
        trips[index].checklist[itemIndex].done.toggle()
        persist()
    }

    /// 清单完成度（诚实统计；清单为空时返回 0/0）。
    func checklistCompletion(for trip: TravelTrip) -> (done: Int, total: Int) {
        let done = trip.checklist.filter(\.done).count
        return (done, trip.checklist.count)
    }

    // MARK: - 默认清单预置

    /// 根据目的地/目的生成默认清单（简单关键词规则，诚实不硬造：
    /// 只补通用必需品与明确对应的证件/出差材料，不臆造具体行程细节）。
    static func defaultChecklist(destination: String, purpose: String?) -> [TravelChecklistItem] {
        var texts = ["身份证件", "充电器与数据线", "换洗衣物", "洗漱用品", "日常药物"]

        if destination.contains("香港") || destination.contains("澳门") {
            texts.append("港澳通行证")
        }
        if Self.overseasKeywords.contains(where: { destination.contains($0) }) {
            texts.append("护照")
        }
        if purpose?.contains("出差") == true {
            texts.append("工作电脑与充电器")
            texts.append("出差材料")
        }
        return texts.map { TravelChecklistItem(text: $0) }
    }

    private static let overseasKeywords = [
        "日本", "韩国", "泰国", "新加坡", "马来西亚", "美国", "英国",
        "法国", "德国", "意大利", "西班牙", "加拿大", "澳大利亚", "迪拜", "欧洲", "海外"
    ]

    // MARK: - 出发前提醒（写入 CareReminderStore，一次性 .custom 提醒）

    /// 为出行排「出发前一天 09:00」「出发前 3 小时」两条提醒；
    /// 对应提醒仍存在于 CareReminderStore 时不重复创建。返回本次新建条数。
    func scheduleDepartureReminders(for trip: TravelTrip, into careReminderStore: CareReminderStore) -> Int {
        var created = 0
        var ids = reminderIDsByTrip[trip.id.uuidString] ?? []
        let existingIDs = Set(careReminderStore.reminders.map(\.id))
        let slots = Self.departureReminderSlots(for: trip)

        for (index, slot) in slots.enumerated() {
            if ids.indices.contains(index), existingIDs.contains(ids[index]) {
                continue
            }
            let reminder = CareReminder(
                title: slot.title,
                time: slot.date,
                category: .custom,
                repeatType: .none,
                enabled: true,
                scheduledDate: slot.date
            )
            careReminderStore.add(reminder)
            if ids.indices.contains(index) {
                ids[index] = reminder.id
            } else {
                ids.append(reminder.id)
            }
            created += 1
        }
        reminderIDsByTrip[trip.id.uuidString] = ids
        persistReminderIDs()
        return created
    }

    /// 两条出发提醒是否都已排好且仍存在于提醒列表。
    func departureRemindersComplete(for trip: TravelTrip, in careReminderStore: CareReminderStore) -> Bool {
        let ids = reminderIDsByTrip[trip.id.uuidString] ?? []
        let existingIDs = Set(careReminderStore.reminders.map(\.id))
        return ids.count >= 2 && ids.allSatisfy { existingIDs.contains($0) }
    }

    /// 出发提醒时间槽：出发前一天 09:00 / 出发前 3 小时（按出发日期时间计算）。
    static func departureReminderSlots(for trip: TravelTrip) -> [(title: String, date: Date)] {
        let calendar = Calendar.current
        let departure = trip.departureDate

        let dayBefore = calendar.date(byAdding: .day, value: -1, to: departure) ?? departure
        var dayBeforeComponents = calendar.dateComponents([.year, .month, .day], from: dayBefore)
        dayBeforeComponents.hour = 9
        dayBeforeComponents.minute = 0
        let dayBeforeDate = calendar.date(from: dayBeforeComponents) ?? dayBefore

        let threeHoursBefore = calendar.date(byAdding: .hour, value: -3, to: departure) ?? departure

        let destination = trip.destination
        return [
            (title: "✈️ 去\(destination)：出发前一天 09:00", date: dayBeforeDate),
            (title: "✈️ 去\(destination)：出发前 3 小时（\(Self.timeText(threeHoursBefore))）", date: threeHoursBefore)
        ]
    }

    // MARK: - 语音解析（简单规则）

    /// 语音解析结果：解析不出的字段保持 nil，由页面弹手动填。
    struct TravelVoiceParseResult: Equatable {
        var destination: String?
        var departureDate: Date?
        var returnDate: Date?
        var purpose: String?

        /// 是否解析出「目的地 + 出发日期」（可自动新建出行）。
        var isComplete: Bool {
            destination != nil && departureDate != nil
        }
    }

    /// 解析语音文本：
    /// - 出发日期：「下周三/周X/星期X」（带「下」取下周对应周几）、「X天后」「后天/明天/今天」
    /// - 目的地：「去XX」（遇 出差/旅行/数字 等关键词截断）
    /// - 时长：「出差X天/旅行X天/玩X天/X天」→ 返程 = 出发 +（天数-1）
    /// - 目的：「出差/旅行/旅游/度假/探亲/回家/团建」首个命中词
    static func parseVoice(_ text: String, referenceDate: Date = Date()) -> TravelVoiceParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = TravelVoiceParseResult()

        if let match = Self.firstMatch(#"去([^\s，。、？！!…0-9一二三四五六七八九十两出差旅游玩飞和]{2,8})"#, in: trimmed) {
            result.destination = match.groups[1]
        }

        var dayOffset: Int?
        if let weekday = Self.weekdayNumber(in: trimmed) {
            let calendar = Calendar.current
            let today = calendar.component(.weekday, from: referenceDate)
            // Calendar：1=周日 … 7=周六 → 转周一制：周一=1 … 周日=7
            let todayMonday = (today + 5) % 7 + 1
            let targetMonday = (weekday + 5) % 7 + 1
            if trimmed.contains("下") {
                let daysToNextMonday = (8 - todayMonday) % 7 == 0 ? 7 : (8 - todayMonday) % 7
                dayOffset = daysToNextMonday + (targetMonday - 1)
            } else {
                var diff = weekday - today
                if diff <= 0 { diff += 7 }
                dayOffset = diff
            }
        } else if let days = Self.parseNumber(Self.firstMatch(#"([0-9一二三四五六七八九十两]{1,3})天\s*后"#, in: trimmed)?.groups[1]) {
            dayOffset = days
        } else if trimmed.contains("后天") {
            dayOffset = 2
        } else if trimmed.contains("明天") || trimmed.contains("明早") || trimmed.contains("明晚") {
            dayOffset = 1
        } else if trimmed.contains("今天") || trimmed.contains("今晚") {
            dayOffset = 0
        }
        if let dayOffset {
            result.departureDate = Calendar.current.date(byAdding: .day, value: dayOffset, to: referenceDate)
        }

        if let departure = result.departureDate,
           let days = Self.parseNumber(Self.firstMatch(#"(?:出差|旅行|旅游|游玩|玩|去)?([0-9一二三四五六七八九十两]{1,3})天"#, in: trimmed)?.groups[1]),
           days > 0 {
            result.returnDate = Calendar.current.date(byAdding: .day, value: days - 1, to: departure)
        }

        for keyword in ["出差", "旅行", "旅游", "度假", "探亲", "回家", "团建"] {
            if trimmed.contains(keyword) {
                result.purpose = keyword
                break
            }
        }

        return result
    }

    /// 「周X/星期X」→ Calendar weekday（1=周日 … 7=周六）。
    private static func weekdayNumber(in text: String) -> Int? {
        let numbers: [String: Int] = ["日": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "天": 1]
        guard let match = Self.firstMatch(#"[周星期]([一二三四五六日天])"#, in: text) else { return nil }
        return numbers[match.groups[1]]
    }

    /// 数字文本 → Int：阿拉伯数字直接转，中文数字支持 一..九、十、十几。
    private static func parseNumber(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        if let value = Int(text) { return value }
        let digits: [String: Int] = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if let value = digits[text] { return value }
        if text.hasPrefix("十") {
            let tail = String(text.dropFirst())
            if tail.isEmpty { return 10 }
            if let value = digits[tail] { return 10 + value }
            return nil
        }
        return nil
    }

    /// 正则首个匹配：整体 + 捕获组；无匹配返回 nil。
    private static func firstMatch(_ pattern: String, in text: String) -> (whole: String, groups: [String])? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            let range = match.range(at: index)
            groups.append(range.location == NSNotFound ? "" : nsText.substring(with: range))
        }
        return (groups[0], groups)
    }

    // MARK: - 日期文案

    static func shortDateText(_ date: Date) -> String {
        Self.shortDateFormatter.string(from: date)
    }

    static func timeText(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    static func fullDateText(_ date: Date) -> String {
        Self.fullDateFormatter.string(from: date)
    }

    static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    // MARK: - 本地持久化

    private func sortTrips() {
        trips.sort { $0.departureDate < $1.departureDate }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TravelTrip].self, from: data)
        else {
            trips = []
            return
        }
        trips = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(trips) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadReminderIDs() {
        if let data = UserDefaults.standard.data(forKey: reminderIDsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            reminderIDsByTrip = decoded
        }
    }

    private func persistReminderIDs() {
        if let data = try? JSONEncoder().encode(reminderIDsByTrip) {
            UserDefaults.standard.set(data, forKey: reminderIDsKey)
        }
    }
}
