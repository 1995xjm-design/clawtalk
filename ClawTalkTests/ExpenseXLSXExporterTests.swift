import XCTest
@testable import ClawTalk

final class ExpenseXLSXExporterTests: XCTestCase {

    private func makeEntry(amount: Double, note: String) -> ExpenseEntry {
        ExpenseEntry(amount: amount, type: .expense, category: .food, note: note)
    }

    /// 导出后读取产物字节（STORE 方式写入 ZIP，XML 内容以原始字节可见）。
    private func exportedData(entries: [ExpenseEntry], scopeTitle: String = "report") throws -> Data {
        let result = try XCTUnwrap(ExpenseXLSXExporter.export(entries: entries, scopeTitle: scopeTitle))
        defer { try? FileManager.default.removeItem(at: result.url) }
        return try Data(contentsOf: result.url)
    }

    private func dataContains(_ data: Data, _ text: String) -> Bool {
        data.range(of: Data(text.utf8)) != nil
    }

    func testExportProducesFile() throws {
        let result = try XCTUnwrap(ExpenseXLSXExporter.export(
            entries: [makeEntry(amount: 12.34, note: "coffee"), makeEntry(amount: 5, note: "bus")],
            scopeTitle: "June"
        ))
        XCTAssertEqual(result.entryCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertTrue(result.url.lastPathComponent.hasPrefix("ClawTalk"))
        XCTAssertTrue(result.url.lastPathComponent.hasSuffix(".xlsx"))
        try? FileManager.default.removeItem(at: result.url)
    }

    func testExportEscapesXMLSpecialCharacters() throws {
        let note = #"A & B <b> "q" 'ap'"#
        let data = try exportedData(entries: [makeEntry(amount: 1, note: note)])
        XCTAssertTrue(dataContains(data, "&amp;"))
        XCTAssertTrue(dataContains(data, "&lt;b&gt;"))
        XCTAssertTrue(dataContains(data, "&quot;q&quot;"))
        XCTAssertTrue(dataContains(data, "&apos;ap&apos;"))
        // 原始未转义片段不应出现在包内 XML 字节中
        XCTAssertFalse(dataContains(data, "A & B"))
    }

    func testExportSanitizesScopeTitleForFileName() throws {
        let result = try XCTUnwrap(ExpenseXLSXExporter.export(
            entries: [],
            scopeTitle: #"a/b\c:d*e?f"g<h>i|j%"#
        ))
        let name = result.url.lastPathComponent
        for ch in #"/\?%*|"<>:"# {
            XCTAssertFalse(name.contains(ch))
        }
        XCTAssertTrue(result.url.lastPathComponent.hasSuffix(".xlsx"))
        try? FileManager.default.removeItem(at: result.url)
    }

    func testExportEmptyEntriesStillProducesFile() throws {
        let result = try XCTUnwrap(ExpenseXLSXExporter.export(entries: [], scopeTitle: "empty"))
        XCTAssertEqual(result.entryCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        try? FileManager.default.removeItem(at: result.url)
    }

    func testExportWritesNumericCellsWithTwoDecimals() throws {
        let data = try exportedData(entries: [makeEntry(amount: 28, note: "x")])
        // 数字固定两位小数（numberText），避免浮点噪声
        XCTAssertTrue(dataContains(data, "<v>28.00</v>"))
    }
}