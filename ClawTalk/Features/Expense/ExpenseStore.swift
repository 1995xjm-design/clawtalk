import Foundation
import Observation

/// 月汇总：本月收入 / 支出 / 结余（结余 = 收入 - 支出）。
struct ExpenseMonthSummary: Equatable {
    var income: Double = 0
    var expense: Double = 0

    var balance: Double { income - expense }
}

/// 记账本地存储：UserDefaults JSON（与 VoiceDiaryViewModel 同款暂存方式）。
/// - 增删改查：add / update / delete / entry(id:)
/// - 月汇总：monthSummary(for:) 按日历月统计收入/支出/结余
/// - 诚实空状态：entries 为空即空，不塞假数据
/// - 主页卡片与本页各自持有实例，都从 UserDefaults 读取同一数据源；
///   返回主页时 ExpenseCardView 调用 reload() 刷新摘要。
@Observable
@MainActor
final class ExpenseStore {
    private static let defaultsKey = "expense_entries_v1"

    /// 全部账目（未排序；排序由调用方按需处理）
    private(set) var entries: [ExpenseEntry] = []

    init() {
        load()
    }

    /// 最新在前的账目（列表用）
    var sortedEntries: [ExpenseEntry] {
        entries.sorted { $0.date > $1.date }
    }

    // MARK: - 增删改查

    /// 新增一条（金额必须 >0，否则返回 nil 不落库）。
    @discardableResult
    func add(
        amount: Double,
        type: ExpenseType,
        category: ExpenseCategory,
        note: String = "",
        photoFileName: String? = nil,
        date: Date = Date()
    ) -> ExpenseEntry? {
        guard amount > 0 else { return nil }
        let entry = ExpenseEntry(date: date, amount: amount, type: type, category: category, note: note, photoFileName: photoFileName)
        entries.append(entry)
        persist()
        return entry
    }

    /// 更新整条（按 id 替换；id 不存在则忽略）
    func update(_ entry: ExpenseEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        persist()
    }

    /// 删除单条
    func delete(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let photoFileName = entries[index].photoFileName {
            deletePhoto(fileName: photoFileName)
        }
        entries.remove(at: index)
        persist()
    }

    /// 按 id 查询
    func entry(id: UUID) -> ExpenseEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - 月汇总

    /// 指定日期所在自然月（默认本月）的收入 / 支出 / 结余。
    func monthSummary(for date: Date = Date()) -> ExpenseMonthSummary {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: date) else {
            return ExpenseMonthSummary()
        }
        var summary = ExpenseMonthSummary()
        for entry in entries where interval.contains(entry.date) {
            switch entry.type {
            case .income: summary.income += entry.amount
            case .expense: summary.expense += entry.amount
            }
        }
        return summary
    }

    /// 本月支出总额（主页卡片摘要用）
    func monthExpenseTotal(for date: Date = Date()) -> Double {
        monthSummary(for: date).expense
    }

    // MARK: - 照片附件

    /// 保存记账照片数据（Application Support/ClawTalk/ExpensePhotos/），返回相对文件名。
    func savePhoto(_ data: Data) -> String? {
        try? ExpensePhotoStore.save(data)
    }

    /// 删除记账照片文件（幂等；账目删除时联动调用）。
    func deletePhoto(fileName: String) {
        ExpensePhotoStore.delete(fileName: fileName)
    }

    /// 按文件名取照片完整 URL（目录创建失败返回 nil）。
    func photoURL(fileName: String) -> URL? {
        ExpensePhotoStore.url(fileName: fileName)
    }


    // MARK: - 持久化

    /// 从 UserDefaults 重新读取（主页卡片返回时刷新摘要）
    func reload() {
        load()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        // 记账数据变化：通知主 App 刷新小组件（WidgetCenter.reloadAllTimelines）
        NotificationCenter.default.post(name: WidgetDataSync.dataDidChangeNotification, object: nil)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([ExpenseEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }
}


/// 记账照片文件存储：Application Support/ClawTalk/ExpensePhotos/（复用 ParkingPhotoStore 模式）。
enum ExpensePhotoStore {

    static func directory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ClawTalk/ExpensePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 保存照片数据（调用方统一转 JPEG），返回相对文件名。
    static func save(_ data: Data) throws -> String {
        let name = "expense-\\(UUID().uuidString.prefix(8).lowercased()).jpg"
        let url = try directory().appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return name
    }

    /// 删除照片文件（幂等）。
    static func delete(fileName: String) {
        guard let url = url(fileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 按文件名拼完整 URL（目录创建失败返回 nil）。
    static func url(fileName: String) -> URL? {
        guard let dir = try? directory() else { return nil }
        return dir.appendingPathComponent(fileName)
    }
}
