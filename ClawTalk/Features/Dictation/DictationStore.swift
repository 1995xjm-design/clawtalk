import Foundation
import Observation

/// 口述文档本地存储：UserDefaults（JSON）增删改查 + 按日期分组列表。
@Observable
@MainActor
final class DictationStore {
    private(set) var notes: [DictationNote] = []

    private let storageKey = "clawtalk_dictation_notes_v1"

    init() {
        load()
    }

    // MARK: - 查询

    var totalCount: Int {
        notes.count
    }

    /// 最近一篇文档的日期（卡片摘要用；无文档返回 nil，卡片显示诚实空状态）。
    var lastNoteDate: Date? {
        notes.first?.date
    }

    /// 按日期分组（最新日期在前，组内按 createdAt 倒序）。
    var groupedByDay: [DictationDayGroup] {
        let grouped = Dictionary(grouping: notes) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            DictationDayGroup(day: day, notes: (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt })
        }
    }

    /// 某一天的口述文档（按 createdAt 倒序）。
    func notes(on day: Date) -> [DictationNote] {
        let start = Calendar.current.startOfDay(for: day)
        return notes
            .filter { Calendar.current.isDate($0.date, inSameDayAs: start) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func note(id: UUID) -> DictationNote? {
        notes.first { $0.id == id }
    }

    // MARK: - 增删改

    @discardableResult
    func add(_ note: DictationNote) -> DictationNote {
        notes.insert(note, at: 0)
        persist()
        return note
    }

    func update(_ note: DictationNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
        persist()
    }

    func delete(id: UUID) {
        notes.removeAll { $0.id == id }
        persist()
    }

    // MARK: - 持久化（UserDefaults JSON）

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([DictationNote].self, from: data) else {
            notes = []
            return
        }
        notes = decoded.sorted { $0.date > $1.date }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

/// 按天分组的口述文档（view-support model，day 作为 Identifiable id）。
struct DictationDayGroup: Identifiable {
    let day: Date
    let notes: [DictationNote]
    var id: Date { day }
}
