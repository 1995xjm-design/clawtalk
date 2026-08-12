import Foundation
import Observation

/// 停车记录本地存储：UserDefaults JSON（记录）+ Application Support（照片文件），
/// 与 HabitStore/ExpenseStore/VoiceMessageFileStore 同款模式，数据只存本机。
@Observable
@MainActor
final class ParkingStore {

    /// 记录按时间倒序（最新在前，主页卡片取 latestRecord）。
    private(set) var records: [ParkingRecord] = []

    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "停车位置", errorMessage)
            }
        }
    }

    private let storageKey = "clawtalk_parking_records_v1"

    init() {
        load()
    }

    // MARK: - 查询

    /// 最近一条停车记录（主页卡片摘要用）。
    var latestRecord: ParkingRecord? {
        records.first
    }

    // MARK: - 增删改

    /// 新增停车记录；`photoData` 可选，有则先落盘再存文件名。
    @discardableResult
    func addRecord(
        latitude: Double,
        longitude: Double,
        address: String?,
        note: String? = nil,
        photoData: Data? = nil
    ) -> ParkingRecord? {
        var photoPath: String?
        if let photoData {
            guard let savedName = savePhoto(photoData) else {
                return nil
            }
            photoPath = savedName
        }

        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = ParkingRecord(
            latitude: latitude,
            longitude: longitude,
            address: address,
            note: trimmedNote?.isEmpty == true ? nil : trimmedNote,
            photoPath: photoPath
        )
        records.insert(record, at: 0)
        persist()
        return record
    }

    /// 整条更新（备注/照片变化后按 id 替换）。
    func update(_ record: ParkingRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        persist()
    }

    /// 删除记录，并清理关联的本地照片文件（不残留孤儿文件）。
    func delete(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if let photoPath = record.photoPath {
            deletePhoto(fileName: photoPath)
        }
        records.removeAll { $0.id == id }
        persist()
    }

    /// 从 UserDefaults 重新读取（主页卡片返回时刷新摘要）。
    func reload() {
        load()
    }

    // MARK: - 照片文件

    /// 把照片数据写入 Application Support，返回文件名；失败走 errorMessage（诚实上报）。
    @discardableResult
    func savePhoto(_ data: Data) -> String? {
        do {
            return try ParkingPhotoStore.save(data)
        } catch {
            errorMessage = "照片保存失败：\(AppErrorText.localized(error.localizedDescription))"
            return nil
        }
    }

    /// 删除照片文件（幂等，文件不存在不报错）。
    func deletePhoto(fileName: String) {
        ParkingPhotoStore.delete(fileName: fileName)
    }

    /// 按文件名取照片完整 URL（行内缩略图用；文件缺失时视图诚实显示占位）。
    func photoURL(fileName: String) -> URL? {
        ParkingPhotoStore.url(fileName: fileName)
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ParkingRecord].self, from: data)
        else {
            records = []
            return
        }
        records = decoded.sorted { $0.recordedAt > $1.recordedAt }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

/// 停车照片文件存储：Application Support/ClawTalk/ParkingPhotos/（复用 VoiceMessageFileStore 模式）。
enum ParkingPhotoStore {

    static func directory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ClawTalk/ParkingPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 保存照片数据，返回文件名（相对文件名，与 UserDefaults 记录解耦）。
    static func save(_ data: Data) throws -> String {
        let name = "parking-\(UUID().uuidString.prefix(8).lowercased()).jpg"
        let url = try directory().appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return name
    }

    /// 删除照片文件（幂等）。
    static func delete(fileName: String) {
        guard let url = url(fileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 按文件名拼完整 URL（目录创建失败时返回 nil，调用方按需兜底）。
    static func url(fileName: String) -> URL? {
        guard let dir = try? directory() else { return nil }
        return dir.appendingPathComponent(fileName)
    }
}

/// 停车记录时间文案（列表/卡片共用，中文短格式）。
enum ParkingDateFormat {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
