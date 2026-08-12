import Foundation
import Observation

/// 文件保险箱存储：重要文件登记（UserDefaults JSON）+ 防丢副本 + 到期本地提醒。
///
/// 职责：
/// - markImportant：登记重要文件。文件在 Documents 下直接引用路径；在临时目录等
///   其他位置则复制到 Application Support/FileVault/ 保存副本（复制失败明确报错，不静默）；
/// - 按 checkIntervalDays 周期调度到期提醒：复用 CareReminderStore（category=自定义、
///   repeatType=.none + scheduledDate 一次性提醒，到点本地通知「「XX」已 N 天未检查」）；
/// - checkIn / 改周期 / 取消标记时先取消旧提醒再重新调度，避免重复提醒。
@Observable
@MainActor
final class FileVaultStore {

    /// 全局单例：主页卡片 / 列表页 / 详情页共用同一数据。
    @MainActor static let shared = FileVaultStore()

    private(set) var files: [ImportantFile] = []
    /// 通知权限被系统拒绝时置 true（数据来自 CareReminderStore，列表页提示，不弹授权框）。
    var notificationPermissionDenied: Bool {
        careReminderStore.notificationPermissionDenied
    }
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "文件保险箱", errorMessage)
            }
        }
    }

    private let storageKey = "clawtalk_file_vault_v1"
    private let careReminderStore: CareReminderStore
    private let fileManager = FileManager.default

    init(careReminderStore: CareReminderStore = CareReminderStore()) {
        self.careReminderStore = careReminderStore
        load()
    }

    // MARK: - 目录

    /// 保险箱副本目录：Application Support/FileVault/（系统备份会带上，防丢）。
    var vaultDirectory: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("FileVault", isDirectory: true)
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - 查询

    /// 到期未检查的文件（今天到期也算）。
    var dueFiles: [ImportantFile] {
        files.filter { $0.isDue }
    }

    /// 到期未检查数量（主页卡片角标）。
    var dueCount: Int {
        dueFiles.count
    }

    /// 是否已登记同名文件（避免重复登记）。
    func isMarked(fileName: String) -> Bool {
        files.contains { $0.fileName == fileName }
    }

    /// 本地文件是否真实存在（诚实状态：文件被删 / 丢失时详情页提示）。
    func fileExists(_ importantFile: ImportantFile) -> Bool {
        guard let path = importantFile.localPath else { return false }
        return fileManager.fileExists(atPath: path)
    }

    // MARK: - 标记重要 / 取消

    /// 把文件登记为重要。
    /// - 文件在 Documents 下 → 直接记录路径引用（不复制，避免双份占用空间）；
    /// - 文件在临时目录等其他位置 → 复制到 Application Support/FileVault/ 防丢。
    /// 复制失败返回 false 并写 errorMessage（不静默）。
    @discardableResult
    func markImportant(
        fileName: String,
        source: ImportantFileSource,
        localURL: URL?,
        note: String? = nil,
        checkIntervalDays: Int = 7
    ) -> Bool {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "文件名不能为空，无法标记。"
            return false
        }
        guard !isMarked(fileName: trimmedName) else {
            errorMessage = "「\(trimmedName)」已登记为重要文件，无需重复标记。"
            return false
        }
        guard let localURL else {
            errorMessage = "缺少本地文件，无法标记。"
            return false
        }
        guard fileManager.fileExists(atPath: localURL.path) else {
            errorMessage = "「\(trimmedName)」在本地不存在，无法标记。"
            return false
        }
        guard checkIntervalDays >= 1 else {
            errorMessage = "检查周期至少 1 天。"
            return false
        }

        var storedPath: String?
        if isInsideDocuments(localURL) {
            storedPath = localURL.path
        } else {
            do {
                storedPath = try copyToVault(from: localURL)
            } catch {
                errorMessage = "复制「\(trimmedName)」到保险箱失败：\(error.localizedDescription)"
                return false
            }
        }

        let size = (try? fileManager.attributesOfItem(atPath: storedPath ?? ""))?[.size] as? Int64 ?? 0
        let file = ImportantFile(
            fileName: trimmedName,
            localPath: storedPath,
            size: size,
            source: source,
            checkIntervalDays: checkIntervalDays,
            note: note
        )
        files.append(file)
        persist()
        scheduleReminder(for: file)
        return true
    }

    /// 取消重要标记：删除登记 + 取消关联提醒；不删除文件本身（文件归属文件传输 / 用户）。
    func unmark(id: String) {
        guard let file = files.first(where: { $0.id == id }) else { return }
        cancelReminder(for: file)
        files.removeAll { $0.id == id }
        persist()
    }

    // MARK: - 检查

    /// 到期未检查的文件列表（列表页 / 卡片角标用）。
    func checkDue() -> [ImportantFile] {
        dueFiles
    }

    /// 标记已检查：更新上次检查时间，并按新周期重新排到期提醒。
    func checkIn(id: String) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].lastCheckedAt = Date()
        persist()
        scheduleReminder(for: files[index])
    }

    // MARK: - 修改

    /// 修改检查周期（1~365 天），按最近一次检查（或登记）时间重新排提醒。
    func updateCheckInterval(days: Int, for id: String) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(days, 1), 365)
        files[index].checkIntervalDays = clamped
        persist()
        scheduleReminder(for: files[index])
    }

    /// 修改备注。
    func updateNote(_ note: String?, for id: String) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].note = note
        persist()
    }

    // MARK: - 防丢副本

    /// localURL 是否在 App Documents 目录内。
    private func isInsideDocuments(_ url: URL) -> Bool {
        let documents = documentsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == documents || path.hasPrefix(documents + "/")
    }

    /// 复制文件到保险箱副本目录（同名追加序号），返回副本路径。
    private func copyToVault(from source: URL) throws -> String {
        try fileManager.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)
        let destination = uniqueURL(in: vaultDirectory, fileName: source.lastPathComponent)
        try fileManager.copyItem(at: source, to: destination)
        return destination.path
    }

    private func uniqueURL(in directory: URL, fileName: String) -> URL {
        let base = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: base.path) else { return base }
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        var index = 1
        while true {
            let candidateName = ext.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    // MARK: - 到期提醒（复用 CareReminderStore）

    /// 排下一次到期提醒：先删旧再排新（标记 / 检查 / 改周期时调用）。
    /// 一次性提醒（repeatType .none + scheduledDate），到点本地通知
    /// 「「文件名」已 N 天未检查，请检查文件是否还在」。
    /// 已逾期（到期日已过）不排新提醒，由列表 / 卡片角标诚实展示。
    private func scheduleReminder(for file: ImportantFile) {
        cancelReminder(for: file)
        guard let fireDate = reminderFireDate(for: file) else { return }
        let reminder = CareReminder(
            title: "「\(file.fileName)」已 \(file.checkIntervalDays) 天未检查，请检查文件是否还在",
            time: fireDate,
            category: .custom,
            repeatType: .none,
            enabled: true,
            scheduledDate: fireDate
        )
        let saved = careReminderStore.add(reminder)
        guard let index = files.firstIndex(where: { $0.id == file.id }) else { return }
        files[index].reminderID = saved.id
        persist()
    }

    private func cancelReminder(for file: ImportantFile) {
        guard let reminderID = file.reminderID else { return }
        careReminderStore.delete(id: reminderID)
    }

    /// 下一次提醒触发时间：检查起点 + 周期；已过则 nil（不排，等用户检查后重排）。
    private func reminderFireDate(for file: ImportantFile) -> Date? {
        let fire = Calendar.current.date(byAdding: .day, value: file.checkIntervalDays, to: file.checkBaseDate) ?? file.checkBaseDate
        return fire > Date() ? fire : nil
    }

    // MARK: - 本地持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ImportantFile].self, from: data)
        else {
            files = []
            return
        }
        files = decoded.sorted { $0.markedAt < $1.markedAt }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(files) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}