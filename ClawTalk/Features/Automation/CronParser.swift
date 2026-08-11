import Foundation

/// 自然语言时间 -> cron 表达式 的本地解析器（5 字段：分 时 日 月 周）。
///
/// 支持规则（解析不了返回 nil，由用户手动填或用模板，不做假解析）：
/// - 每天 / 每日 / 天天：日字段 *
/// - 每工作日 / 工作日：周字段 1-5
/// - 每周末 / 周末：周字段 0,6
/// - 每周X / 星期X / 礼拜X（X = 一二三四五六日天）：周字段对应数字
/// - 时间：阿拉伯/中文数字 + 点/时，支持 半/一刻/三刻/分
/// - 时段：上午/早上/中午/下午/傍晚/晚上；无显式时间时按语境给默认值
enum CronParser {

    // MARK: - 自然语言 -> cron

    /// 例："每天上午9点" -> "0 9 * * *"；"每周五下午" -> "0 15 * * 5"；"每工作日" -> "0 9 * * 1-5"
    static func cron(from text: String) -> String? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }
        guard !isUnsupported(normalized) else { return nil }
        // 没有任何计划信号（时间/星期说法）时按解析失败处理，避免把普通句子当成「每天 9 点」
        guard hasScheduleSignal(normalized) else { return nil }

        let dayOfWeek = parseDayOfWeek(normalized) ?? "*"
        guard let (hour, minute) = parseTime(normalized) else { return nil }
        return "\(minute) \(hour) * * \(dayOfWeek)"
    }

    // MARK: - cron -> 中文描述

    /// 例："0 9 * * 1-5" -> "每工作日 09:00"；解析不了返回 nil（由调用方回退显示原始 cron）
    static func describe(cron: String) -> String? {
        let fields = cron.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 else { return nil }
        let minuteField = fields[0]
        let hourField = fields[1]
        let dayOfMonth = fields[2]
        let month = fields[3]
        let dayOfWeek = fields[4]

        guard let hour = Int(hourField),
              let minute = Int(minuteField),
              (0...23).contains(hour),
              (0...59).contains(minute) else { return nil }

        let timeText = String(format: "%02d:%02d", hour, minute)

        if month != "*" {
            guard let m = Int(month), (1...12).contains(m) else { return nil }
            if dayOfMonth != "*" {
                guard let d = Int(dayOfMonth), (1...31).contains(d) else { return nil }
                return "每年 \(m) 月 \(d) 日 \(timeText)"
            }
            return "每年 \(m) 月 \(timeText)"
        }

        if dayOfMonth != "*" {
            guard let d = Int(dayOfMonth), (1...31).contains(d) else { return nil }
            if dayOfWeek != "*" { return nil }
            return "每月 \(d) 日 \(timeText)"
        }

        switch dayOfWeek {
        case "*":
            return "每天 \(timeText)"
        case "1-5", "1,2,3,4,5":
            return "每工作日 \(timeText)"
        case "0,6", "6,0", "0,6,7", "6,0,7", "7,0":
            return "每周末 \(timeText)"
        default:
            guard let weekday = Int(dayOfWeek), (0...7).contains(weekday) else { return nil }
            return "每周\(weekdayName(weekday)) \(timeText)"
        }
    }

    // MARK: - 私有实现

    /// 去掉不影响时间的常见标点（保留冒号，用于 "9:30"）
    private static func normalize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for char in "，。！？、；!？…" {
            result = result.replacingOccurrences(of: String(char), with: "")
        }
        return result
    }

    /// 明确不支持的句式（诚实返回 nil，避免解析出错误的计划）
    private static func isUnsupported(_ text: String) -> Bool {
        if text.contains("每月") || text.contains("每隔") || text.contains("每小时")
            || text.contains("每半小时") || text.contains("每两") || text.contains("每三天") {
            return true
        }
        // 日期式说法（如「每月1号」「每天9号」）当前不支持
        if !captures(text, #"\d{1,2}\s*号"#).isEmpty { return true }
        // 多个星期字符（如「每周一三五」）当前不支持，避免解析出单一星期
        let weekdayChars: [Character] = ["一", "二", "三", "四", "五", "六", "日", "天"]
        let count = weekdayChars.filter { text.contains($0) }.count
        return count >= 2
    }

    /// 文本里是否含「计划信号」：星期说法或时间说法（都不含则解析失败）
    private static func hasScheduleSignal(_ text: String) -> Bool {
        let dayMarkers = ["每天", "每日", "天天", "工作日", "周末", "每周", "星期", "礼拜"]
        if dayMarkers.contains(where: { text.contains($0) }) { return true }

        let timeMarkers = [
            "点", "时", "上午", "早上", "早晨", "清晨", "中午", "下午", "傍晚", "晚上",
            "收盘", "开盘"
        ]
        if timeMarkers.contains(where: { text.contains($0) }) { return true }

        // 阿拉伯数字时间（如 "9:30" / "9点"）
        if !captures(text, #"\d{1,2}\s*[:：点时]"#).isEmpty { return true }

        return false
    }

    private static func parseDayOfWeek(_ text: String) -> String? {
        if text.contains("每天") || text.contains("每日") || text.contains("天天") { return nil }
        if text.contains("工作日") { return "1-5" }
        if text.contains("周末") { return "0,6" }
        let mapping: [(Character, Int)] = [
            ("一", 1), ("二", 2), ("三", 3), ("四", 4), ("五", 5), ("六", 6),
            ("日", 0), ("天", 0)
        ]
        for (char, value) in mapping where text.contains(char) {
            return "\(value)"
        }
        return nil
    }

    private static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        var hour: Int?
        var minute: Int?

        // 1) 阿拉伯数字整组："9:30" / "9点30" / "9时30分"
        let whole = captures(text, #"(\d{1,2})\s*[:：点时]\s*(\d{1,2})"#)
        if whole.count == 2,
           let h = Int(whole[0]), let m = Int(whole[1]),
           h <= 23, m <= 59 {
            hour = h
            minute = m
        }

        // 2) 阿拉伯数字只有小时："9点" / "9时"
        if hour == nil,
           let h = captures(text, #"(\d{1,2})\s*[点时]"#).first.flatMap(Int.init),
           h <= 23 {
            hour = h
        }

        // 3) 中文数字小时："九点" / "十二点半"
        if hour == nil,
           let chinese = captures(text, #"([零一二两三四五六七八九十]+)\s*[点时]"#).first,
           let h = chineseNumber(chinese) {
            hour = h
        }

        // 4) 分钟（无显式分钟时默认 0）
        if minute == nil {
            if text.contains("半") {
                minute = 30
            } else if text.contains("三刻") {
                minute = 45
            } else if text.contains("一刻") {
                minute = 15
            } else if let m = captures(text, #"(\d{1,2})\s*分"#).first.flatMap(Int.init), m <= 59 {
                minute = m
            } else if let chinese = captures(text, #"([零一二两三四五六七八九十]+)\s*分"#).first,
                      let m = chineseNumber(chinese), m <= 59 {
                minute = m
            } else {
                minute = 0
            }
        }

        // 5) 时段：下午/傍晚/晚上 +12（12 点整回 0）；无显式时间按语境给默认值
        let isAfternoonOrEvening = text.contains("下午") || text.contains("傍晚") || text.contains("晚上")
        if let h = hour {
            if isAfternoonOrEvening {
                hour = h == 12 ? 0 : (h < 12 ? h + 12 : h)
            }
        } else {
            let fallback = defaultTime(for: text)
            hour = fallback.hour
            minute = fallback.minute
        }

        guard let h = hour, let m = minute, (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// 无显式时间时的语境默认值
    private static func defaultTime(for text: String) -> (hour: Int, minute: Int) {
        if text.contains("收盘") { return (15, 0) }
        if text.contains("开盘") { return (9, 30) }
        if text.contains("中午") { return (12, 0) }
        if text.contains("下午") || text.contains("傍晚") { return (15, 0) }
        if text.contains("晚上") { return (20, 0) }
        if text.contains("早上") || text.contains("早晨") || text.contains("清晨") || text.contains("上午") {
            return (9, 0)
        }
        return (9, 0)
    }

    /// 中文数字 -> Int（支持 0-99，含 十/二十/三十/十二 等写法）
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

    private static func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "一"
        case 2: return "二"
        case 3: return "三"
        case 4: return "四"
        case 5: return "五"
        case 6: return "六"
        default: return "日"
        }
    }

    // MARK: - 正则辅助

    private static func captures(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let swiftRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}
