import Foundation

/// 居家健康提醒类别：久坐 / 喝水 / 用药 / 自定义。
enum CareReminderCategory: String, Codable, CaseIterable, Identifiable, Equatable {
    case sedentary = "久坐"
    case water = "喝水"
    case medication = "用药"
    case custom = "自定义"

    var id: String { rawValue }
}

/// 提醒重复方式。
/// - none：一次性，到点响一次（指定日期或今天该时间已过则不再触发）
/// - daily：每天同一时间
/// - workday：工作日（周一至周五）同一时间
enum CareReminderRepeat: String, Codable, CaseIterable, Identifiable, Equatable {
    case none = "none"
    case daily = "daily"
    case workday = "workday"

    var id: String { rawValue }

    /// 展示用名称。
    var displayName: String {
        switch self {
        case .none: return "一次"
        case .daily: return "每天"
        case .workday: return "工作日"
        }
    }
}

/// 一条居家健康提醒（本地 UserDefaults 存储 + 本地通知调度共用）。
/// 重复提醒只取「时:分」；一次性提醒可用 scheduledDate 指定完整日期
/// （语音输入「明天下午3点」会生成），由 CareReminderStore 排通知。
struct CareReminder: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    /// 提醒时间（重复提醒只取时/分；一次性提醒取时/分用于展示与兜底）
    var time: Date
    var category: CareReminderCategory
    var repeatType: CareReminderRepeat
    /// 开关：关闭后取消已排的本地通知
    var enabled: Bool
    /// 一次性提醒（.none）的指定日期；nil 时按 time 的时:分走「今天/下一次」逻辑。
    /// 语音输入「明天下午3点」会生成此字段（含完整日期），到点只响一次。
    var scheduledDate: Date?
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        time: Date = Date(),
        category: CareReminderCategory,
        repeatType: CareReminderRepeat = .daily,
        enabled: Bool = true,
        scheduledDate: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.time = time
        self.category = category
        self.repeatType = repeatType
        self.enabled = enabled
        self.scheduledDate = scheduledDate
        self.createdAt = createdAt
    }
}