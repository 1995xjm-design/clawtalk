import XCTest
@testable import ClawTalk

@MainActor
final class ExpenseStoreTests: XCTestCase {

    /// 与 ExpenseStore 私有 defaultsKey 字面量保持一致（该 key 为 private，测试按字面量隔离）。
    private static let storeKey = "expense_entries_v1"
    private var savedPhotos: [String] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
        for name in savedPhotos {
            ExpensePhotoStore.delete(fileName: name)
        }
        savedPhotos = []
        super.tearDown()
    }

    private func makeStore() -> ExpenseStore {
        ExpenseStore()
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    // MARK: - 增删改查

    func testAddValidEntry() {
        let store = makeStore()
        let added = store.add(amount: 28.5, type: .expense, category: .food, note: "lunch")
        let entry = try! XCTUnwrap(added)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entry(id: entry.id)?.amount, 28.5)
        XCTAssertEqual(store.entry(id: entry.id)?.category, .food)
    }

    func testAddRejectsNonPositiveAmount() {
        let store = makeStore()
        XCTAssertNil(store.add(amount: 0, type: .expense, category: .food))
        XCTAssertNil(store.add(amount: -3, type: .income, category: .other))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testUpdateReplacesById() {
        let store = makeStore()
        let entry = store.add(amount: 10, type: .expense, category: .food, note: "before")!
        var updated = entry
        updated.note = "after"
        updated.amount = 12
        store.update(updated)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].note, "after")
        XCTAssertEqual(store.entries[0].amount, 12)
    }

    func testUpdateUnknownIDIsNoop() {
        let store = makeStore()
        let entry = store.add(amount: 10, type: .expense, category: .food)!
        var ghost = entry
        ghost.id = UUID()
        ghost.note = "ghost"
        store.update(ghost)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].note, "")
    }

    func testDeleteRemovesEntry() {
        let store = makeStore()
        let a = store.add(amount: 1, type: .expense, category: .food)!
        let b = store.add(amount: 2, type: .expense, category: .food)!
        store.delete(a.id)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertNil(store.entry(id: a.id))
        XCTAssertNotNil(store.entry(id: b.id))
    }

    func testDeleteUnknownIDIsNoop() {
        let store = makeStore()
        store.add(amount: 1, type: .expense, category: .food)
        store.delete(UUID())
        XCTAssertEqual(store.entries.count, 1)
    }

    // MARK: - 排序与月汇总

    func testSortedEntriesNewestFirst() {
        let store = makeStore()
        store.add(amount: 1, type: .expense, category: .food, date: date(year: 2026, month: 6, day: 1))
        store.add(amount: 2, type: .expense, category: .food, date: date(year: 2026, month: 7, day: 15))
        store.add(amount: 3, type: .expense, category: .food, date: date(year: 2026, month: 6, day: 30))
        XCTAssertEqual(store.sortedEntries.map(\.amount), [2, 3, 1])
    }

    func testMonthSummary() {
        let store = makeStore()
        let inMonth = date(year: 2026, month: 6, day: 10)
        store.add(amount: 100, type: .income, category: .other, date: inMonth)
        store.add(amount: 30.5, type: .expense, category: .food, date: inMonth)
        store.add(amount: 999, type: .expense, category: .food, date: date(year: 2026, month: 7, day: 1))

        let summary = store.monthSummary(for: inMonth)
        XCTAssertEqual(summary.income, 100)
        XCTAssertEqual(summary.expense, 30.5, accuracy: 0.001)
        XCTAssertEqual(summary.balance, 69.5, accuracy: 0.001)
        XCTAssertEqual(store.monthExpenseTotal(for: inMonth), 30.5, accuracy: 0.001)
    }

    // MARK: - 照片文件名唯一性

    func testPhotoFileNamesAreUnique() {
        let store = makeStore()
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let first = store.savePhoto(data)
        let second = store.savePhoto(data)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
        if let first, let second {
            savedPhotos += [first, second]
            XCTAssertTrue(first.hasPrefix("expense-"))
            XCTAssertTrue(first.hasSuffix(".jpg"))
            XCTAssertTrue(second.hasPrefix("expense-"))
            XCTAssertTrue(second.hasSuffix(".jpg"))
            let stem = first.dropFirst("expense-".count).dropLast(".jpg".count)
            XCTAssertEqual(stem.count, 8)
            XCTAssertTrue(stem.allSatisfy { $0.isHexDigit })
        }
    }

    func testDeleteEntryRemovesPhoto() {
        let store = makeStore()
        let name = store.savePhoto(Data([0xFF, 0xD8]))!
        savedPhotos.append(name)
        let url = ExpensePhotoStore.url(fileName: name)!
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let entry = store.add(amount: 5, type: .expense, category: .other, note: "", photoFileName: name)!
        store.delete(entry.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeletePhotoRemovesFile() throws {
        let name = try ExpensePhotoStore.save(Data([0xFF, 0xD8]))
        savedPhotos.append(name)
        let url = try XCTUnwrap(ExpensePhotoStore.url(fileName: name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        ExpensePhotoStore.delete(fileName: name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}