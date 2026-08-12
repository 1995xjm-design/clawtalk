import Foundation

/// 语音新建提醒的自然语言解析：把「明天下午3点提醒我开会」拆成
/// 标题「开会」+ 时间（明天 15:00）+ 类别。解析不出时间返回 .failure，
/// 由调用方弹 alert 手动填，不做假解析。
///
/// 解析规则表：
/// - 日期词：大后天(+3天) / 后天(+2) / 明天·明儿·明日·明早·明晚(+1) / 今天·今晚·今夜·今日·现在·马上(0)
/// - 时间：优先复用 CronParser（「下午3点」「晚上8点」「上午9点半」等）；
///   CronParser 拒收时自抠显式时间（「记一下」里的「一」会触发其多星期启发式）；
///   无显式时间按语境给默认值（凌晨6点 / 早上·上午9点 / 中午12点 / 下午·傍晚15点 /
///   晚上·今晚20点 / 现在·马上=1分钟后）
/// - 重复：每天·每日·天天 → daily；工作日·每工作日 → workday；
///   每周X / 周末 → 暂不支持返回失败（诚实，弹窗手动填）
/// - 类别：喝水·饮水·倒水→water；吃药·用药·服药→medication；久坐·站起来·起身→sedentary；其余→custom
/// - 标题：去掉日期词/时间短语/时段词/星期词/重复词/命令短语后剩余文本；去完为空则回退原句
enum VoiceReminderParser {

    /// 解析结果：一次性提醒（.none）用 scheduledDate（含完整日期），
    /// 重复提醒用 time（只取时:分）。
    struct Draft {
        let title: String
        let time: Date
        let repeatType: CareReminderRepeat
        let scheduledDate: Date?
        let category: CareReminderCategory
    }

    enum Failure {
        /// 没解析出时间（需要手动填）
        case noTime
        /// 句式暂不支持（如每周五），附说明
        case unsupported(String)
    }

    static func parse(_ raw: String) -> Result<Draft, Failure> {
        let text = normalize(raw)
        guard !text.isEmpty else { return .failure(.noTime) }

        // 1) 重复方式（先按关键词粗判，星期字段可再修正）
        var repeatType: CareReminderRepeat = .none
        if text.contains("每天") || text.contains("每日") || text.contains("天天") {
            repeatType = .daily
        } else if text.contains("工作日") {
            repeatType = .workday
        }

        // 一天多次的句式当前不支持，诚实转手动填写
        if text.contains("早晚") || text.contains("每天两次") {
            return .failure(.noTime)
        }

        // 2) 日期偏移（一次性提醒用）
        let dayOffset = dayOffset(from: text)

        // 3) 时间：优先 CronParser；拒收时自抠显式时间；再无则按语境默认
        guard let (hour, minute, dayOfWeek) = extractTime(from: text) else {
            return .failure(.noTime)
        }

        // 4) 星期字段修正重复方式；只认明确的星期说法，避免「明天/今天」里的「天」被当成星期天
        if let dayOfWeek, dayOfWeek != "*" {
            if dayOfWeek == "1-5" {
                repeatType = .workday
            } else if dayOfWeek == "0,6" || dayOfWeek == "6,0" || dayOfWeek == "0,6,7" {
                return .failure(.unsupported("周末重复暂不支持，请在弹窗里手动设置"))
            } else if hasExplicitWeekdayMarker(text) {
                return .failure(.unsupported("按星期重复暂不支持，请在弹窗里手动设置"))
            }
        }

        let calendar = Calendar.current
        let now = Date()
        let timeOfDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now

        // 5) 一次性提醒：拼日期+时间；已过点自动顺延到下一次
        if repeatType == .none {
            var date = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
            date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
            if date <= now {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return .success(
                Draft(
                    title: extractTitle(from: raw),
                    time: timeOfDay,
                    repeatType: .none,
                    scheduledDate: date,
                    category: category(from: text)
                )
            )
        }

        return .success(
            Draft(
                title: extractTitle(from: raw),
                time: timeOfDay,
                repeatType: repeatType,
                scheduledDate: nil,
                category: category(from: text)
            )
        )
    }

    // MARK: - 标题

    /// 从整句里抠出提醒标题：「明天下午3点提醒我开会」→「开会」；抠不出有效标题回退原句。
    static func extractTitle(from raw: String) -> String {
        var result = normalize(raw)

        for word in dateWords {
            result = result.replacingOccurrences(of: word, with: "")
        }
        for pattern in timePatterns {
            result = removeMatches(result, pattern)
        }
        for word in periodWords {
            result = result.replacingOccurrences(of: word, with: "")
        }
        // 星期词含「每周X」整体，必须先于「每周」拆词移除
        for word in weekdayWords {
            result = result.replacingOccurrences(of: word, with: "")
        }
        for word in repeatWords {
            result = result.replacingOccurrences(of: word, with: "")
        }
        for phrase in commandPhrases {
            result = result.replacingOccurrences(of: phrase, with: "")
        }

        // 清理残留标点，连续空白折叠成单个空格
        for char in "，。！？、；：!?…·（）()" {
            result = result.replacingOccurrences(of: String(char), with: "")
        }
        let cleaned = result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    // MARK: - 时间

    /// 返回 (时, 分, cron 星期字段)；星期字段为 nil 表示由语境推断（无星期概念）。
    private static func extractTime(from text: String) -> (hour: Int, minute: Int, dayOfWeek: String?)? {
        if let cron = CronParser.cron(from: text) {
            let fields = cron.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count == 5,
                  let minute = Int(fields[0]),
                  let hour = Int(fields[1]),
                  (0...23).contains(hour),
                  (0...59).contains(minute)
            else { return nil }
            return (hour, minute, fields[4])
        }
        // CronParser 拒收（如「记一下」含「一」触发其多星期启发式）时自抠显式时间
        if let explicit = explicitTime(from: text) {
            return (explicit.hour, explicit.minute, nil)
        }
        guard let contextual = contextualTime(from: text) else { return nil }
        return (contextual.hour, contextual.minute, nil)
    }

    /// 直接抠「X点Y分 / X点半 / X点 / X:Y / 中文数字」显式时间（含上午/下午调整）。
    private static func explicitTime(from text: String) -> (hour: Int, minute: Int)? {
        var hour: Int?
        var minute: Int?

        // 1) 阿拉伯数字整组："9:30" / "9点30分" / "9时30分"
        let whole = captures(text, #"(\d{1,2})\s*[:：点时]\s*(\d{1,2})"#)
        if whole.count == 2,
           let h = Int(whole[0]), let m = Int(whole[1]),
           h <= 23, m <= 59 {
            hour = h
            minute = m
        }

        // 2) 阿拉伯数字 小时 + 半："9点半"
        if hour == nil,
           let h = captures(text, #"(\d{1,2})\s*[点时]\s*半"#).first.flatMap(Int.init),
           h <= 23 {
            hour = h
            minute = 30
        }

        // 3) 阿拉伯数字 只有小时："9点" / "9时"
        if hour == nil,
           let h = captures(text, #"(\d{1,2})\s*[点时]"#).first.flatMap(Int.init),
           h <= 23 {
            hour = h
        }

        // 4) 中文数字 小时 + 分："九点三十分"
        if hour == nil {
            let chineseWhole = captures(text, #"([零一二两三四五六七八九十]+)\s*[点时]\s*([零一二两三四五六七八九十]+)\s*分"#)
            if chineseWhole.count == 2,
               let h = chineseNumber(chineseWhole[0]),
               let m = chineseNumber(chineseWhole[1]),
               h <= 23, m <= 59 {
                hour = h
                minute = m
            }
        }

        // 5) 中文数字 小时 + 半："九点半"
        if hour == nil,
           let chinese = captures(text, #"([零一二两三四五六七八九十]+)\s*[点时]\s*半"#).first,
           let h = chineseNumber(chinese),
           h <= 23 {
            hour = h
            minute = 30
        }

        // 6) 中文数字 只有小时："九点"
        if hour == nil,
           let chinese = captures(text, #"([零一二两三四五六七八九十]+)\s*[点时]"#).first,
           let h = chineseNumber(chinese),
           h <= 23 {
            hour = h
        }

        guard let h = hour else { return nil }

        // 7) 分钟兜底：半/刻/分；没有显式分钟默认 0
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

        // 8) 时段：下午/傍晚/晚上 +12（12 点整回 0，与 CronParser 一致）
        let isAfternoonOrEvening = text.contains("下午") || text.contains("傍晚") || text.contains("晚上")
        let adjustedHour = isAfternoonOrEvening ? (h == 12 ? 0 : (h < 12 ? h + 12 : h)) : h

        guard let m = minute, (0...23).contains(adjustedHour), (0...59).contains(m) else { return nil }
        return (adjustedHour, m)
    }

    /// 无显式数字时间时的语境默认值（仅在句子里确实有「时段词/日期词」时才生效）。
    private static func contextualTime(from text: String) -> (hour: Int, minute: Int)? {
        if text.contains("现在") || text.contains("马上") {
            let next = Date().addingTimeInterval(60)
            let components = Calendar.current.dateComponents([.hour, .minute], from: next)
            return (components.hour ?? 9, components.minute ?? 0)
        }
        if text.contains("凌晨") { return (6, 0) }
        if text.contains("中午") { return (12, 0) }
        if text.contains("下午") || text.contains("傍晚") { return (15, 0) }
        if text.contains("晚上") || text.contains("夜晚") || text.contains("深夜")
            || text.contains("今晚") || text.contains("今夜") {
            return (20, 0)
        }
        if text.contains("早上") || text.contains("早晨") || text.contains("清晨")
            || text.contains("上午") || text.contains("明早") {
            return (9, 0)
        }
        return nil
    }

    // MARK: - 星期 / 日期 / 类别

    /// 是否有明确的星期说法（每周/星期/礼拜/周X），避免「明天/今天」里的「天」误判为星期天。
    private static func hasExplicitWeekdayMarker(_ text: String) -> Bool {
        if ["每周", "星期", "礼拜"].contains(where: { text.contains($0) }) { return true }
        return !captures(text, #"周[一二三四五六日天]"#).isEmpty
    }

    private static func dayOffset(from text: String) -> Int {
        if text.contains("大后天") { return 3 }
        if text.contains("后天") { return 2 }
        if text.contains("明天") || text.contains("明儿") || text.contains("明日")
            || text.contains("明早") || text.contains("明晚") {
            return 1
        }
        return 0
    }

    private static func category(from text: String) -> CareReminderCategory {
        if text.contains("喝水") || text.contains("饮水") || text.contains("倒水") { return .water }
        if text.contains("吃药") || text.contains("用药") || text.contains("服药") { return .medication }
        if text.contains("久坐") || text.contains("站起来") || text.contains("起身") { return .sedentary }
        return .custom
    }

    // MARK: - 词表

    private static let dateWords = [
        "大后天", "后天", "明天", "明儿", "明日", "明早", "明晚",
        "今天", "今晚", "今夜", "今日", "现在", "马上"
    ]

    private static let periodWords = [
        "凌晨", "清晨", "早晨", "早上", "上午", "中午", "下午", "傍晚",
        "晚上", "夜晚", "深夜"
    ]

    private static let repeatWords = [
        "每工作日", "每个工作日", "每天", "每日", "天天", "工作日", "周末", "每周"
    ]

    /// 星期词（含「每周X」整体），先于「每周」拆词移除
    private static let weekdayWords: [String] = {
        let chars = ["一", "二", "三", "四", "五", "六", "日", "天"]
        var words: [String] = []
        for char in chars {
            words.append("星期\(char)")
            words.append("礼拜\(char)")
            words.append("每周\(char)")
            words.append("周\(char)")
        }
        return words
    }()

    /// 命令短语（长优先，先去掉长的避免残留半截）
    private static let commandPhrases = [
        "帮我定个提醒", "帮我设个提醒", "帮我加个提醒", "帮我创建提醒", "帮我新建提醒",
        "帮我设置提醒", "帮我提醒我", "记得提醒我", "帮我记一下", "帮我提醒",
        "提醒我一下", "提醒一下", "定个提醒", "设个提醒", "加个提醒", "创建提醒",
        "新建提醒", "设置提醒", "来个提醒", "安排提醒", "记一下", "别忘了", "别忘",
        "麻烦", "记住", "提醒我", "提醒"
    ]

    private static let timePatterns = [
        #"\d{1,2}\s*[:：点时]\s*\d{1,2}\s*分?"#,
        #"\d{1,2}\s*[点时]\s*半"#,
        #"\d{1,2}\s*[点时]"#,
        #"[零一二两三四五六七八九十]+\s*[点时]\s*[零一二两三四五六七八九十]+\s*分"#,
        #"[零一二两三四五六七八九十]+\s*[点时]\s*半"#,
        #"[零一二两三四五六七八九十]+\s*[点时]"#
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

    private static func captures(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let swiftRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[swiftRange])
        }
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
}