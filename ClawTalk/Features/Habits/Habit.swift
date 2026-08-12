import Foundation

/// 习惯模型（本地存储 + 打卡 + 连续天数）。
///
/// 日期键约定：`checkIns` 的 key 为 `yyyy-MM-dd`（本地时区），value 为当天打卡时刻；
/// 同一天只记一次打卡（重复打卡不覆盖、不重复计数）。
///
/// 重复日约定：`repeatDays` 为 Calendar weekday 数字（1=周日 … 7=周六，周一=2），
/// 与 CareReminderStore 的通知调度同一套日历惯例。
struct Habit: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    /// SF Symbol 名称（列表/卡片图标）
    var icon: String
    /// 每周重复日：Calendar weekday（1=周日 … 7=周六，周一=2），已去重排序
    var repeatDays: [Int]
    /// 每日目标次数（可选，仅展示参考；打卡按「每天一次」记录）
    var targetPerDay: Int?
    /// 打卡记录：日期键 "yyyy-MM-dd" → 当天打卡时刻
    var checkIns: [String: Date]
    /// 联动 CareReminderStore 的每日提醒 id（无则不联动）
    var linkedReminderID: String?
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        icon: String = "checkmark.seal.fill",
        repeatDays: [Int] = Array(1...7),
        targetPerDay: Int? = nil,
        checkIns: [String: Date] = [:],
        linkedReminderID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        let valid = repeatDays.filter { (1...7).contains($0) }
        self.repeatDays = Array(Set(valid)).sorted()
        self.targetPerDay = targetPerDay
        self.checkIns = checkIns
        self.linkedReminderID = linkedReminderID
        self.createdAt = createdAt
    }

    // MARK: - 连续天数

    /// 当前连续打卡天数（以今天为基准，跨月/跨年正确）。
    ///
    /// 规则：
    /// - 今天已打卡且今日应打卡 → 从今天往前连续数；
    /// - 今天应打卡但还没打 → 今天不计入、也不中断（从昨天往前数）；
    /// - 今天休息（repeatDays 不含今天）→ 跳过今天往前数；
    /// - 只统计「应打卡日」：休息日跳过不中断；某应打卡日缺卡即中断。
    var streak: Int {
        streak(asOf: Date())
    }

    /// 以任意日期为基准计算连续天数（测试/跨月跨年验证用）。
    func streak(asOf date: Date) -> Int {
        let calendar = Calendar.current
        var count = 0
        var cursor = date

        // 今天：已打卡且今日应打卡 → 计入；其余情况从昨天开始（不因今天未打而中断）
        if isChecked(on: cursor), isDue(on: cursor) {
            count += 1
        }
        guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { return count }
        cursor = previous

        // 往前连续：应打卡日必须已打卡；休息日跳过不中断
        while true {
            if isDue(on: cursor) {
                guard isChecked(on: cursor),
                      let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                    break
                }
                count += 1
                cursor = previous
            } else {
                guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
            }
        }
        return count
    }

    // MARK: - 打卡查询

    /// 该日是否安排（repeatDays 含该日 weekday）。
    func isDue(on date: Date) -> Bool {
        repeatDays.contains(Calendar.current.component(.weekday, from: date))
    }

    /// 该日是否已打卡。
    func isChecked(on date: Date) -> Bool {
        checkIns[Self.dateKey(for: date)] != nil
    }

    /// 该日打卡时刻（未打卡返回 nil）。
    func checkInTime(on date: Date) -> Date? {
        checkIns[Self.dateKey(for: date)]
    }

    // MARK: - 展示辅助

    /// 重复日摘要：每天 / 工作日 / 周末 / 周一/三/五。
    var repeatSummary: String {
        let sorted = repeatDays
        if sorted == Array(1...7) { return "每天" }
        if sorted == [2, 3, 4, 5, 6] { return "工作日" }
        if sorted == [1, 7] { return "周末" }
        return sorted.map(Self.weekdayName).joined(separator: "/")
    }

    /// Calendar weekday → 中文（1=周日 … 7=周六）。
    static func weekdayName(_ weekday: Int) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        guard (1...7).contains(weekday) else { return "每天" }
        return names[weekday - 1]
    }

    /// 日期 → 打卡键 "yyyy-MM-dd"（本地时区，跨月/跨年正确）。
    static func dateKey(for date: Date) -> String {
        dateKeyFormatter.string(from: date)
    }

    private static let dateKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
