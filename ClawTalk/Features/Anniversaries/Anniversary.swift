import Foundation

/// 纪念日类型：生日 / 纪念日 / 节日 / 自定义。
enum AnniversaryType: String, Codable, CaseIterable, Identifiable, Equatable {
    case birthday = "生日"
    case anniversary = "纪念日"
    case holiday = "节日"
    case custom = "自定义"

    var id: String { rawValue }

    /// 默认是否每年重复：生日/纪念日/节日默认每年重复；自定义默认一次性（表单里可改）。
    var defaultsToYearly: Bool {
        switch self {
        case .birthday, .anniversary, .holiday: return true
        case .custom: return false
        }
    }
}

/// 一条纪念日记录（本地 UserDefaults 存储 + 本地通知调度共用，与 CareReminder 同款）。
///
/// 日期语义：
/// - repeatsYearly == true（生日/纪念日/节日）：date 只取「月/日」，每年按固定公历月日重复；
///   诚实限制：农历节日（春节/中秋等）每年公历日期不同，当前版本按固定公历月日每年重复，
///   农历节日需要每年手动调整日期，不做假推算。
/// - repeatsYearly == false（一次性）：date 是完整日期，到点提醒一次，过期后不再提醒。
///
/// remindDaysBefore：提前提醒天数数组，例如 [7, 1] = 提前 7 天和提前 1 天各提醒一次；
/// 0 表示纪念日当天提醒。
struct Anniversary: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    /// 纪念日日期：每年重复时只取月/日；一次性时取完整日期。
    var date: Date
    var type: AnniversaryType
    /// 是否每年重复（决定倒计时「下一个」的算法与通知是否每年重建）。
    var repeatsYearly: Bool
    /// 提前提醒天数（0 = 当天提醒）。
    var remindDaysBefore: [Int]
    var note: String?
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        date: Date,
        type: AnniversaryType,
        repeatsYearly: Bool? = nil,
        remindDaysBefore: [Int] = [1],
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.type = type
        self.repeatsYearly = repeatsYearly ?? type.defaultsToYearly
        self.remindDaysBefore = remindDaysBefore
        self.note = note
        self.createdAt = createdAt
    }
}
