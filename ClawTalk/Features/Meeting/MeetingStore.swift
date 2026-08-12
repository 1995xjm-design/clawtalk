import Foundation
import Observation

/// 会议纪要本地存储：UserDefaults（JSON）增删改查 + 按日期列表。
@Observable
@MainActor
final class MeetingStore {
    private(set) var notes: [MeetingNote] = []

    private let storageKey = "clawtalk_meeting_notes_v1"

    init() {
        load()
    }

    // MARK: - 查询

    var totalCount: Int {
        notes.count
    }

    /// 最近一条纪要的日期（卡片摘要用；无纪要返回 nil，卡片显示诚实空状态）。
    var lastNoteDate: Date? {
        notes.first?.date
    }

    /// 按日期分组（最新日期在前，组内按 createdAt 倒序）。
    var groupedByDay: [MeetingDayGroup] {
        let grouped = Dictionary(grouping: notes) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            MeetingDayGroup(day: day, notes: (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt })
        }
    }

    /// 某一天的纪要列表（按 createdAt 倒序）。
    func notes(on day: Date) -> [MeetingNote] {
        let start = Calendar.current.startOfDay(for: day)
        return notes
            .filter { Calendar.current.isDate($0.date, inSameDayAs: start) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func note(id: UUID) -> MeetingNote? {
        notes.first { $0.id == id }
    }

    // MARK: - 增删改

    @discardableResult
    func add(_ note: MeetingNote) -> MeetingNote {
        notes.insert(note, at: 0)
        persist()
        return note
    }

    func update(_ note: MeetingNote) {
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
              let decoded = try? JSONDecoder().decode([MeetingNote].self, from: data) else {
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

/// Grouped meeting notes by day (view-support model, day as Identifiable id).
struct MeetingDayGroup: Identifiable {
    let day: Date
    let notes: [MeetingNote]
    var id: Date { day }
}
