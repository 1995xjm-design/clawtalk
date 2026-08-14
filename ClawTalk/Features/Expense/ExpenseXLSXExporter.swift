import Foundation

/// 记账报表 Excel（xlsx）导出器：本机生成 Office Open XML 包（SpreadsheetML），
/// 数据直接来自 ExpenseStore 真实账目（不造假）；生成文件交给页面 ShareLink 分享。
///
/// 结构：
/// - 「记账明细」：按时间倒序的账目（日期/类型/类别/金额/备注）+ 支出/收入/结余合计
/// - 「类别汇总」：按类别统计支出/收入/结余
/// - 打包用内置极简 ZIP 写入器（STORE 不压缩），Excel / WPS / Numbers 均可打开。
enum ExpenseXLSXExporter {

    struct ExportResult {
        let url: URL
        let entryCount: Int
    }

    /// 导出账目为 xlsx，返回临时文件 URL；失败返回 nil。
    static func export(entries: [ExpenseEntry], scopeTitle: String, now: Date = Date()) -> ExportResult? {
        let sorted = entries.sorted { $0.date > $1.date }
        let dateStamp = Self.dateStamp(now)
        let safeScope = Self.safeFileName(scopeTitle)
        let fileName = "ClawTalk记账报表-\(safeScope)-\(dateStamp).xlsx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        guard let data = xlsxData(entries: sorted) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return ExportResult(url: url, entryCount: sorted.count)
        } catch {
            return nil
        }
    }

    // MARK: - 包内容

    private static func xlsxData(entries: [ExpenseEntry]) -> Data? {
        let files: [(String, Data)] = [
            ("[Content_Types].xml", Data(Self.contentTypesXML.utf8)),
            ("_rels/.rels", Data(Self.rootRelationshipsXML.utf8)),
            ("xl/workbook.xml", Data(Self.workbookXML.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(Self.workbookRelationshipsXML.utf8)),
            ("xl/styles.xml", Data(Self.stylesXML.utf8)),
            ("xl/worksheets/sheet1.xml", Data(Self.detailSheetXML(entries: entries).utf8)),
            ("xl/worksheets/sheet2.xml", Data(Self.categorySheetXML(entries: entries).utf8))
        ]
        return ExpenseMiniZIPWriter.archive(
            files: files.map { ExpenseMiniZIPWriter.FileEntry(name: $0.0, data: $0.1) }
        )
    }

    // MARK: - 记账明细表

    private static func detailSheetXML(entries: [ExpenseEntry]) -> String {
        var rows: [String] = []

        let headerCells = [
            cellRef("A1", "日期", style: 1),
            cellRef("B1", "类型", style: 1),
            cellRef("C1", "类别", style: 1),
            cellRef("D1", "金额（元）", style: 1),
            cellRef("E1", "备注", style: 1)
        ]
        rows.append("<row r=\"1\">" + headerCells.joined() + "</row>")

        var incomeTotal = 0.0
        var expenseTotal = 0.0
        var rowIndex = 2
        for entry in entries {
            switch entry.type {
            case .income: incomeTotal += entry.amount
            case .expense: expenseTotal += entry.amount
            }
            var cells = [
                cellRef("A\(rowIndex)", Self.dateTimeText(entry.date)),
                cellRef("B\(rowIndex)", entry.type.rawValue),
                cellRef("C\(rowIndex)", entry.category.rawValue),
                "<c r=\"D\(rowIndex)\"><v>\(Self.numberText(entry.amount))</v></c>"
            ]
            if !entry.note.isEmpty {
                cells.append(cellRef("E\(rowIndex)", entry.note))
            }
            rows.append("<row r=\"\(rowIndex)\">" + cells.joined() + "</row>")
            rowIndex += 1
        }

        let balance = incomeTotal - expenseTotal
        let totals: [(String, Double)] = [
            ("支出合计", expenseTotal),
            ("收入合计", incomeTotal),
            ("结余", balance)
        ]
        for (label, value) in totals {
            let cells = [
                cellRef("A\(rowIndex)", label, style: 2),
                "<c r=\"D\(rowIndex)\" s=\"2\"><v>\(Self.numberText(value))</v></c>"
            ]
            rows.append("<row r=\"\(rowIndex)\">" + cells.joined() + "</row>")
            rowIndex += 1
        }

        return sheetXML(cols: detailColumns, rows: rows)
    }

    // MARK: - 类别汇总表

    private static func categorySheetXML(entries: [ExpenseEntry]) -> String {
        var rows: [String] = []

        let headerCells = [
            cellRef("A1", "类别", style: 1),
            cellRef("B1", "支出（元）", style: 1),
            cellRef("C1", "收入（元）", style: 1),
            cellRef("D1", "结余（元）", style: 1)
        ]
        rows.append("<row r=\"1\">" + headerCells.joined() + "</row>")

        var rowIndex = 2
        var totalExpense = 0.0
        var totalIncome = 0.0
        for category in ExpenseCategory.allCases {
            var income = 0.0
            var expense = 0.0
            for entry in entries where entry.category == category {
                switch entry.type {
                case .income: income += entry.amount
                case .expense: expense += entry.amount
                }
            }
            totalIncome += income
            totalExpense += expense
            let cells = [
                cellRef("A\(rowIndex)", category.rawValue),
                "<c r=\"B\(rowIndex)\"><v>\(Self.numberText(expense))</v></c>",
                "<c r=\"C\(rowIndex)\"><v>\(Self.numberText(income))</v></c>",
                "<c r=\"D\(rowIndex)\"><v>\(Self.numberText(income - expense))</v></c>"
            ]
            rows.append("<row r=\"\(rowIndex)\">" + cells.joined() + "</row>")
            rowIndex += 1
        }

        let totalCells = [
            cellRef("A\(rowIndex)", "合计", style: 2),
            "<c r=\"B\(rowIndex)\" s=\"2\"><v>\(Self.numberText(totalExpense))</v></c>",
            "<c r=\"C\(rowIndex)\" s=\"2\"><v>\(Self.numberText(totalIncome))</v></c>",
            "<c r=\"D\(rowIndex)\" s=\"2\"><v>\(Self.numberText(totalIncome - totalExpense))</v></c>"
        ]
        rows.append("<row r=\"\(rowIndex)\">" + totalCells.joined() + "</row>")

        return sheetXML(cols: categoryColumns, rows: rows)
    }

    // MARK: - 单元格与样式

    private static let detailColumns = """
    <col min="1" max="1" width="18" customWidth="1"/>
    <col min="2" max="2" width="8" customWidth="1"/>
    <col min="3" max="3" width="10" customWidth="1"/>
    <col min="4" max="4" width="12" customWidth="1"/>
    <col min="5" max="5" width="30" customWidth="1"/>
    """

    private static let categoryColumns = """
    <col min="1" max="1" width="10" customWidth="1"/>
    <col min="2" max="2" width="12" customWidth="1"/>
    <col min="3" max="3" width="12" customWidth="1"/>
    <col min="4" max="4" width="12" customWidth="1"/>
    """

    private static func sheetXML(cols: String, rows: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetViews><sheetView workbookViewId="0"/></sheetViews>
        <sheetFormatPr defaultRowHeight="15"/>
        <cols>
        \(cols)
        </cols>
        <sheetData>
        \(rows.joined(separator: "\n"))
        </sheetData>
        </worksheet>
        """
    }

    /// 文本单元格（inlineStr），可选样式（1 = 加粗表头，2 = 加粗+底色合计）。
    private static func cellRef(_ ref: String, _ text: String, style: Int? = nil) -> String {
        let styleAttr = style.map { " s=\"\($0)\"" } ?? ""
        return "<c r=\"\(ref)\" t=\"inlineStr\"\(styleAttr)><is><t>\(xmlEscape(text))</t></is></c>"
    }

    /// 数字单元格文本：固定两位小数，避免浮点噪声（Excel 按数字显示）。
    private static func numberText(_ value: Double) -> String {
        let cents = Int((value * 100).rounded())
        let sign = cents < 0 ? "-" : ""
        let absCents = abs(cents)
        return "\(sign)\(absCents / 100).\(String(format: "%02d", absCents % 100))"
    }

    private static func dateTimeText(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    private static func dateStamp(_ date: Date) -> String {
        dateStampFormatter.string(from: date)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "账目" : cleaned
    }

    /// XML 转义 + 剔除 XML 1.0 不允许的控制字符。
    private static func xmlEscape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                let value = scalar.value
                if value == 0x09 || value == 0x0A || value == 0x0D || value >= 0x20 {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    // MARK: - OOXML 固定部件

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    </Types>
    """

    private static let rootRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static let workbookXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <sheets>
    <sheet name="记账明细" sheetId="1" r:id="rId1"/>
    <sheet name="类别汇总" sheetId="2" r:id="rId2"/>
    </sheets>
    </workbook>
    """

    private static let workbookRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <fonts count="2">
    <font><sz val="11"/><name val="Calibri"/></font>
    <font><b/><sz val="11"/><name val="Calibri"/></font>
    </fonts>
    <fills count="3">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFDDEBF7"/><bgColor indexed="64"/></patternFill></fill>
    </fills>
    <borders count="1">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    </borders>
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
    <cellXfs count="3">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
    </cellXfs>
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
    </styleSheet>
    """
}

/// 极简 ZIP 写入器：仅支持 STORE（不压缩）条目，用于打包 xlsx 等 OOXML 文件。
/// 结构：Local File Header + 数据 + Central Directory + End of Central Directory。
enum ExpenseMiniZIPWriter {

    struct FileEntry {
        let name: String
        let data: Data
    }

    static func archive(files: [FileEntry]) -> Data {
        var localParts: [Data] = []
        var centralParts: [Data] = []
        var offset: UInt32 = 0

        for file in files {
            let nameData = Data(file.name.utf8)
            let crc = Self.crc32(file.data)
            let size = file.data.count

            // Local File Header
            var local = Data()
            Self.appendUInt32(0x04034b50, to: &local)
            Self.appendUInt16(20, to: &local)   // version needed
            Self.appendUInt16(0, to: &local)    // flags
            Self.appendUInt16(0, to: &local)    // method: stored
            Self.appendUInt16(0, to: &local)    // mod time
            Self.appendUInt16(0, to: &local)    // mod date
            Self.appendUInt32(crc, to: &local)
            Self.appendUInt32(UInt32(size), to: &local)
            Self.appendUInt32(UInt32(size), to: &local)
            Self.appendUInt16(UInt16(nameData.count), to: &local)
            Self.appendUInt16(0, to: &local)    // extra len
            local.append(nameData)
            local.append(file.data)
            localParts.append(local)

            // Central Directory Header
            var central = Data()
            Self.appendUInt32(0x02014b50, to: &central)
            Self.appendUInt16(20, to: &central) // version made by
            Self.appendUInt16(20, to: &central) // version needed
            Self.appendUInt16(0, to: &central)  // flags
            Self.appendUInt16(0, to: &central)  // method
            Self.appendUInt16(0, to: &central)  // mod time
            Self.appendUInt16(0, to: &central)  // mod date
            Self.appendUInt32(crc, to: &central)
            Self.appendUInt32(UInt32(size), to: &central)
            Self.appendUInt32(UInt32(size), to: &central)
            Self.appendUInt16(UInt16(nameData.count), to: &central)
            Self.appendUInt16(0, to: &central)  // extra len
            Self.appendUInt16(0, to: &central)  // comment len
            Self.appendUInt16(0, to: &central)  // disk number
            Self.appendUInt16(0, to: &central)  // internal attrs
            Self.appendUInt32(0, to: &central)  // external attrs
            Self.appendUInt32(offset, to: &central)
            central.append(nameData)
            centralParts.append(central)

            offset += UInt32(local.count)
        }

        var result = Data()
        for part in localParts { result.append(part) }
        let centralOffset = offset
        for part in centralParts { result.append(part) }

        // End of Central Directory
        var eocd = Data()
        Self.appendUInt32(0x06054b50, to: &eocd)
        Self.appendUInt16(0, to: &eocd)
        Self.appendUInt16(0, to: &eocd)
        Self.appendUInt16(UInt16(files.count), to: &eocd)
        Self.appendUInt16(UInt16(files.count), to: &eocd)
        Self.appendUInt32(UInt32(result.count - Int(centralOffset)), to: &eocd)
        Self.appendUInt32(centralOffset, to: &eocd)
        Self.appendUInt16(0, to: &eocd)
        result.append(eocd)
        return result
    }

    // MARK: - 二进制写入

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    // MARK: - CRC32（标准查表法）

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            table[n] = c
        }
        return table
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}