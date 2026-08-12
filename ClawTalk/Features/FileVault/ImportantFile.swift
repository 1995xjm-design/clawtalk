import Foundation

/// 重要文件来源：下载（文件传输） / 分享（分享面板） / 导入（文件 App）。
enum ImportantFileSource: String, Codable, CaseIterable, Identifiable, Equatable {
    case download = "下载"
    case share = "分享"
    case imported = "导入"

    var id: String { rawValue }

    /// 展示名称。
    var displayName: String { rawValue }

    /// SF Symbol 图标（列表 / 详情用）。
    var icon: String {
        switch self {
        case .download: return "arrow.down.circle.fill"
        case .share: return "square.and.arrow.up.fill"
        case .imported: return "tray.and.arrow.down.fill"
        }
    }
}

/// 一条「重要文件」登记（本地 UserDefaults JSON 存储 + CareReminderStore 到期提醒共用）。
///
/// 防丢逻辑：
/// - 文件在 Documents 下（如文件传输的 Documents/files/）→ 直接记录路径引用，不复制；
/// - 文件在临时目录 / 其他位置（如文件 App 导入）→ 标记时复制到
///   Application Support/FileVault/ 保存副本，原文件被清 / 被移走也不丢。
/// 检查提醒：按 checkIntervalDays 周期排本地通知，到点提醒检查。
struct ImportantFile: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var fileName: String
    /// 本地文件路径（绝对路径）；复制进保险箱时指向 Application Support/FileVault/ 下的副本。
    var localPath: String?
    var size: Int64
    var source: ImportantFileSource
    let markedAt: Date
    /// 检查周期（天），默认 7。
    var checkIntervalDays: Int
    /// 上次检查时间；从未检查为 nil（按登记时间起算周期）。
    var lastCheckedAt: Date?
    var note: String?
    /// 关联的 CareReminderStore 提醒 ID：改周期 / 检查 / 取消标记时先删旧再排新，避免重复提醒。
    var reminderID: String?

    init(
        id: String = UUID().uuidString,
        fileName: String,
        localPath: String?,
        size: Int64,
        source: ImportantFileSource,
        markedAt: Date = Date(),
        checkIntervalDays: Int = 7,
        lastCheckedAt: Date? = nil,
        note: String? = nil,
        reminderID: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.localPath = localPath
        self.size = size
        self.source = source
        self.markedAt = markedAt
        self.checkIntervalDays = checkIntervalDays
        self.lastCheckedAt = lastCheckedAt
        self.note = note
        self.reminderID = reminderID
    }

    /// 本地文件 URL（localPath 为空时返回 nil，详情页显示诚实「文件已丢失」）。
    var localURL: URL? {
        guard let localPath else { return nil }
        return URL(fileURLWithPath: localPath)
    }

    /// 检查周期起点：优先上次检查时间，从未检查按登记时间。
    var checkBaseDate: Date {
        lastCheckedAt ?? markedAt
    }

    /// 下次检查到期日（checkBaseDate + 周期）。
    var dueDate: Date {
        Calendar.current.date(byAdding: .day, value: checkIntervalDays, to: checkBaseDate) ?? checkBaseDate
    }

    /// 距到期剩余天数：>0 未到期；0 今天到期；<0 已逾期。
    var daysUntilDue: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let due = calendar.startOfDay(for: dueDate)
        return calendar.dateComponents([.day], from: today, to: due).day ?? 0
    }

    /// 是否到期需要检查（今天到期也算）。
    var isDue: Bool {
        daysUntilDue <= 0
    }

    /// 自上次检查（或登记）起已未检查天数。
    var uncheckedDays: Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: checkBaseDate)
        let now = calendar.startOfDay(for: Date())
        return max(0, calendar.dateComponents([.day], from: start, to: now).day ?? 0)
    }
}