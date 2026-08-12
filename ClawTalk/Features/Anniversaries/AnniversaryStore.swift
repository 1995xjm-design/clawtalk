import Foundation
import Observation
import UserNotifications

/// 纪念日提醒存储：UserDefaults（JSON 序列化）增删改查 + 倒计时 + 本地通知调度。
///
/// 通知调度策略（诚实说明，与 CareReminderStore 的关系）：
/// - 不走 CareReminderStore：它的重复方式只有 none/daily/workday，无法表达「每年某月某日」，
///   所以这里直接调度 UNUserNotificationCenter，不硬塞进它的模型。
/// - 每年重复的纪念日：用 Calendar 触发器排「下一次」的一次性通知（dateMatching 含年/月/日），
///   由本 store 每次初始化 / 增删改时「每年重建」下一年排程（rescheduleAll）。
///   限制（如实标注）：若纪念日过去后一整年用户都没打开过 App，下一年提醒不会自动补排；
///   App 每次启动都会重建排程，打开即自愈。
/// - 提醒时间固定为当天 09:00（当前版本没有独立设置项；后续要可配置可扩展 remindTime 字段）。
@Observable
@MainActor
final class AnniversaryStore {

    private(set) var anniversaries: [Anniversary] = []
    /// 通知权限被系统拒绝时置 true（列表页用于提示，不重复弹授权框）
    private(set) var notificationPermissionDenied = false
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "纪念日", errorMessage)
            }
        }
    }

    private let storageKey = "clawtalk_anniversaries_v1"
    /// 提醒通知统一发在当天 09:00（提前天数都相对这个时刻算）。
    static let defaultReminderHour = 9
    static let defaultReminderMinute = 0

    init() {
        load()
        rescheduleAll()
    }

    // MARK: - 查询

    func anniversary(id: String) -> Anniversary? {
        anniversaries.first { $0.id == id }
    }

    /// 未来将到来的纪念日（按日期升序），供卡片「最近一个」与列表排序使用。
    var upcomingAnniversaries: [(anniversary: Anniversary, occurrence: Date)] {
        anniversaries.compactMap { anniversary in
            guard let occurrence = nextOccurrence(for: anniversary) else { return nil }
            return (anniversary, occurrence)
        }
        .sorted { $0.occurrence < $1.occurrence }
    }

    /// 最近一个将到来的纪念日（无则 nil，卡片显示诚实空态）。
    var nextAnniversary: Anniversary? {
        upcomingAnniversaries.first?.anniversary
    }

    /// 下一个纪念日日期：
    /// - 每年重复：date 的「月/日」在当年/次年的下一个实例（今天当天算今天）；
    /// - 一次性：date 在今天或以后返回，已过返回 nil（列表诚实显示「已过」，不再倒计时/提醒）。
    func nextOccurrence(for anniversary: Anniversary) -> Date? {
        let calendar = Calendar.current
        let now = Date()

        guard anniversary.repeatsYearly else {
            return calendar.startOfDay(for: anniversary.date) >= calendar.startOfDay(for: now)
                ? anniversary.date
                : nil
        }

        let month = calendar.component(.month, from: anniversary.date)
        let day = calendar.component(.day, from: anniversary.date)
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.month = month
        components.day = day

        // 2月29日（闰日生日）：非闰年回退到 2月28日，诚实处理不跨月。
        let year = calendar.component(.year, from: now)
        let isLeapYear = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        if month == 2 && day == 29 && !isLeapYear {
            components.day = 28
        }

        guard let candidate = calendar.date(from: components) else { return nil }
        if calendar.startOfDay(for: candidate) < calendar.startOfDay(for: now) {
            return calendar.date(byAdding: .year, value: 1, to: candidate)
        }
        return candidate
    }

    /// 倒计时：今天到下一个纪念日的天数（今天=0，明天=1）；一次性已过返回 nil。
    func daysUntilNext(for anniversary: Anniversary) -> Int? {
        guard let occurrence = nextOccurrence(for: anniversary) else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: occurrence)
        ).day
    }

    // MARK: - 增删改查

    @discardableResult
    func add(_ anniversary: Anniversary) -> Anniversary {
        anniversaries.append(anniversary)
        sortByNextOccurrence()
        persist()
        reschedule(for: anniversary)
        return anniversary
    }

    func update(_ anniversary: Anniversary) {
        guard let index = anniversaries.firstIndex(where: { $0.id == anniversary.id }) else { return }
        anniversaries[index] = anniversary
        sortByNextOccurrence()
        persist()
        reschedule(for: anniversary)
    }

    func delete(id: String) {
        guard let anniversary = anniversaries.first(where: { $0.id == id }) else { return }
        cancelNotifications(for: anniversary)
        anniversaries.removeAll { $0.id == id }
        persist()
    }

    // MARK: - 本地持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Anniversary].self, from: data)
        else {
            anniversaries = []
            return
        }
        anniversaries = decoded
        sortByNextOccurrence()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(anniversaries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 列表按「下一个纪念日日期」升序；一次性已过的排最后（按创建时间）。
    private func sortByNextOccurrence() {
        anniversaries.sort { lhs, rhs in
            let left = nextOccurrence(for: lhs)
            let right = nextOccurrence(for: rhs)
            switch (left, right) {
            case (nil, nil):
                return lhs.createdAt < rhs.createdAt
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (left?, right?):
                return left < right
            }
        }
    }

    // MARK: - 本地通知调度

    /// 重建全部排程（启动时 / 数据变化时调用）：每年重复的纪念日靠这里「每年重建」
    /// 下一年的一次性通知。主智能体可在 App 启动处额外调用一次，保证整年未打开后自愈。
    func rescheduleAll() {
        let snapshot = anniversaries
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(
                withIdentifiers: snapshot.flatMap { Self.notificationIdentifiers(for: $0) }
            )
            for anniversary in snapshot {
                await scheduleNotifications(for: anniversary)
            }
        }
    }

    /// 取消旧通知后按当前状态重新调度（add/update 时调用）。
    private func reschedule(for anniversary: Anniversary) {
        cancelNotifications(for: anniversary)
        Task { await scheduleNotifications(for: anniversary) }
    }

    private func cancelNotifications(for anniversary: Anniversary) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: Self.notificationIdentifiers(for: anniversary)
        )
    }

    private func scheduleNotifications(for anniversary: Anniversary) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            if settings.authorizationStatus == .denied {
                notificationPermissionDenied = true
            }
            return
        }
        notificationPermissionDenied = false

        // 一次性且已过：不排（列表诚实显示「已过」）。
        guard let occurrence = nextOccurrence(for: anniversary) else { return }
        guard !anniversary.remindDaysBefore.isEmpty else { return }

        let calendar = Calendar.current
        let content = UNMutableNotificationContent()
        content.title = "\(anniversary.type.rawValue)提醒"
        content.body = anniversary.name
        content.sound = .default
        content.userInfo = ["anniversary_id": anniversary.id]

        for offset in anniversary.remindDaysBefore {
            // 提前 offset 天；跨年偏移（如 1月1日提前 7 天 = 去年 12月25日）已过时不排，
            // 上次重建时已排过，倒计时不受影响。
            guard let rawDate = calendar.date(byAdding: .day, value: -offset, to: occurrence) else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: rawDate)
            components.hour = Self.defaultReminderHour
            components.minute = Self.defaultReminderMinute
            guard let fireDate = calendar.date(from: components), fireDate > Date() else { continue }

            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = Self.notificationIdentifier(for: anniversary, offset: offset)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                errorMessage = "纪念日通知调度失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 通知标识

    private static func notificationBaseIdentifier(for anniversaryID: String) -> String {
        "anniversary-\(anniversaryID)"
    }

    private static func notificationIdentifier(for anniversary: Anniversary, offset: Int) -> String {
        "\(notificationBaseIdentifier(for: anniversary.id))-\(offset)"
    }

    static func notificationIdentifiers(for anniversary: Anniversary) -> [String] {
        anniversary.remindDaysBefore.map { offset in
            "\(notificationBaseIdentifier(for: anniversary.id))-\(offset)"
        }
    }
}

// MARK: - 语音解析

/// 语音新建纪念日的自然语言解析：把「5月20号是结婚纪念日」拆成
/// 日期（5月20日）+ 名称（结婚纪念日）+ 类型（纪念日）。
/// 解析不出日期返回 .failure，由页面弹表单手动填（名称预填），不做假解析。
///
/// 解析规则表：
/// - 日期（优先级从高到低）：
///   1. X月X日 / X月X号 / X月X（阿拉伯数字，如「5月20号」）
///   2. X月X日 / X月X号（中文数字，如「五月二十号」）
///   3. X.X / X/X（阿拉伯数字，如「5.20」）
///   4. 今天 / 明天 / 后天 / 大后天（一次性纪念日用；生日/节日这类每年重复的
///      建议说月日，否则年份语义模糊）
/// - 名称：去掉日期短语、命令短语（帮我记一下 / 添加纪念日 / 记住…）、
///   语气词（是 / 的 / 了）后剩余文本；去完为空回退为类型名。
/// - 类型：含「生日」→ 生日；含「纪念日」→ 纪念日；含「节」→ 节日；其余 → 自定义。
/// - 每年重复：默认按类型（生日/纪念日/节日每年，自定义一次性）；句子里含「每年」强制每年。
/// - 诚实限制：农历节日（春节/中秋等）每年公历日期不同，语音按固定公历月日解析，
///   农历节日需要手动改日期；「下个月20号」这类相对月日暂不支持（弹表单手动填）。
enum AnniversaryVoiceParser {

    /// 解析草稿：直接落库为 Anniversary（repeatsYearly 已按类型/「每年」关键词算好）。
    struct Draft {
        let name: String
        let date: Date
        let type: AnniversaryType
        let repeatsYearly: Bool
    }

    enum Failure: Error {
        /// 没解析出日期（需要手动填）
        case noDate
    }

    static func parse(_ raw: String) -> Result<Draft, Failure> {
        let text = normalize(raw)
        guard !text.isEmpty else { return .failure(.noDate) }

        guard let date = extractDate(from: text) else { return .failure(.noDate) }

        let type = type(from: text)
        let repeatsYearly = text.contains("每年") || text.contains("年年") || type.defaultsToYearly
        return .success(
            Draft(
                name: extractName(from: text, type: type),
                date: date,
                type: type,
                repeatsYearly: repeatsYearly
            )
        )
    }

    /// 只抠名称（解析失败时给表单预填用；抠不出返回 ""）。
    static func extractNameOnly(from raw: String) -> String {
        let text = normalize(raw)
        guard !text.isEmpty else { return "" }
        return extractName(from: text, type: type(from: text))
    }

    // MARK: - 日期

    private static func extractDate(from text: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()

        if let (month, day) = monthDay(from: text) {
            return dateWithMonthDay(month, day, from: now, calendar: calendar)
        }

        // 相对日期（今天/明天/后天/大后天）：一次性纪念日用。
        let offset: Int
        if text.contains("大后天") {
            offset = 3
        } else if text.contains("后天") {
            offset = 2
        } else if text.contains("明天") || text.contains("明儿") || text.contains("明日") {
            offset = 1
        } else if text.contains("今天") || text.contains("今日") || text.contains("现在") {
            offset = 0
        } else {
            return nil
        }
        return calendar.date(byAdding: .day, value: offset, to: now)
    }

    /// 形如「5月20号 / 五月二十日 / 5.20」→ (月, 日)；格式不符返回 nil。
    private static func monthDay(from text: String) -> (month: Int, day: Int)? {
        if let match = firstMatch(text, #"(\d{1,2})\s*月\s*(\d{1,2})\s*(?:号|日)?"#),
           let month = Int(match[0]), let day = Int(match[1]),
           (1...12).contains(month), (1...31).contains(day) {
            return (month, day)
        }
        if let match = firstMatch(text, #"([零一二两三四五六七八九十]+)\s*月\s*([零一二两三四五六七八九十]+)\s*(?:号|日)?"#),
           let month = chineseNumber(match[0]), let day = chineseNumber(match[1]),
           (1...12).contains(month), (1...31).contains(day) {
            return (month, day)
        }
        if let match = firstMatch(text, #"(?<!\d)(\d{1,2})\s*[./]\s*(\d{1,2})"#),
           let month = Int(match[0]), let day = Int(match[1]),
           (1...12).contains(month), (1...31).contains(day) {
            return (month, day)
        }
        return nil
    }

    /// 用「月/日」生成日期：今年对应月日已过则顺延到明年（生日/纪念日语义都是「下一次」）。
    private static func dateWithMonthDay(_ month: Int, _ day: Int, from now: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.month = month
        components.day = day
        // 2月29日非闰年回退 2月28日
        let year = calendar.component(.year, from: now)
        let isLeapYear = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        if month == 2 && day == 29 && !isLeapYear {
            components.day = 28
        }
        guard let candidate = calendar.date(from: components) else { return nil }
        if calendar.startOfDay(for: candidate) < calendar.startOfDay(for: now) {
            return calendar.date(byAdding: .year, value: 1, to: candidate)
        }
        return candidate
    }

    // MARK: - 名称 / 类型

    private static func extractName(from text: String, type: AnniversaryType) -> String {
        var result = text
        for pattern in datePatterns {
            result = removeMatches(result, pattern)
        }
        for phrase in commandPhrases {
            result = result.replacingOccurrences(of: phrase, with: "")
        }
        for filler in ["是", "的", "了", "一个", "为"] {
            result = result.replacingOccurrences(of: filler, with: "")
        }
        for char in "，。！？、；：!?…·（）()" {
            result = result.replacingOccurrences(of: String(char), with: "")
        }
        let cleaned = result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? type.rawValue : cleaned
    }

    private static func type(from text: String) -> AnniversaryType {
        if text.contains("生日") { return .birthday }
        if text.contains("纪念日") { return .anniversary }
        if text.contains("节") { return .holiday }
        return .custom
    }

    // MARK: - 词表

    /// 名称里要抠掉的日期短语（与 monthDay 的三种写法保持一致）。
    private static let datePatterns = [
        #"\d{1,2}\s*月\s*\d{1,2}\s*(?:号|日)?"#,
        #"[零一二两三四五六七八九十]+\s*月\s*[零一二两三四五六七八九十]+\s*(?:号|日)?"#,
        #"(?<!\d)\d{1,2}\s*[./]\s*\d{1,2}"#
    ]

    /// 命令短语（长优先，避免残留半截）；注意不含「纪念日/生日/节日」本身，
    /// 否则会把「结婚纪念日」这类名称里的关键词抠掉。
    private static let commandPhrases = [
        "帮我记一下", "帮我记住", "帮我记个", "帮我添加", "帮我加个", "帮我新建", "帮我创建", "帮我设置",
        "添加纪念日", "新建纪念日", "创建纪念日", "设个纪念日", "加个纪念日", "设置纪念日", "添加节日",
        "记一下", "记住", "记得", "提醒我", "添加", "新建", "创建", "设置", "设个", "加个", "设为",
        "每年", "年年", "帮我", "提醒", "标记", "记个", "请", "把", "给"
    ]

    // MARK: - 文本辅助

    private static func normalize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for char in "，。！？、；!?…" {
            result = result.replacingOccurrences(of: String(char), with: "")
        }
        return result
    }

    private static func removeMatches(_ text: String, _ pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// 正则首个匹配的全部捕获组；无匹配返回 nil。
    private static func firstMatch(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let swiftRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    /// 中文数字 → Int（支持 1-31：一、十二、二十、三十一）。
    private static func chineseNumber(_ text: String) -> Int? {
        let single: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        if text.count == 1, let first = text.first, let value = single[first] {
            return value
        }
        if text.contains("十") {
            let parts = text.components(separatedBy: "十")
            let tens = parts[0].isEmpty ? 1 : (parts[0].first.flatMap { single[$0] } ?? 0)
            let ones = parts.count > 1 && !parts[1].isEmpty ? (parts[1].first.flatMap { single[$0] } ?? 0) : 0
            return tens * 10 + ones
        }
        return nil
    }
}
