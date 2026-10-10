import Foundation

/// Edits cells of an .xlsx into a NEW file (file operations stage 3, 2026-10-11; docs/design/FILE-OPERATIONS.md). The sheet
/// XML is edited in place, so styles, other sheets, charts and everything else in the package stay as they were; the
/// original file is never written. Text goes in as inline strings (the shared-string table is left alone), numbers as
/// numbers, formulas as formulas with "recalculate on open" set, since this app does not calculate them.
enum XLSXEditor {
    struct CellEdit: Codable, Equatable, Sendable {
        var sheet: String
        var cell: String
        var value: String?
        var formula: String?

        init(sheet: String, cell: String, value: String? = nil, formula: String? = nil) {
            self.sheet = sheet; self.cell = cell; self.value = value; self.formula = formula
        }

        /// The model writes numbers as numbers ("value": 2000) as often as text; both are accepted.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sheet = (try? c.decode(String.self, forKey: .sheet)) ?? ""
            cell = try c.decode(String.self, forKey: .cell)
            formula = try? c.decode(String.self, forKey: .formula)
            if let text = try? c.decode(String.self, forKey: .value) { value = text }
            else if let number = try? c.decode(Double.self, forKey: .value) {
                value = number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
            } else if let flag = try? c.decode(Bool.self, forKey: .value) { value = flag ? "TRUE" : "FALSE" }
            else { value = nil }
        }
    }

    struct CellChange: Equatable, Sendable {
        let sheet: String
        let cell: String
        let before: String
        let after: String
    }

    enum Failure: LocalizedError {
        case unreadable(String), unknownSheet(String), badCell(String), zip(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "「\(name)」を開けませんでした"
            case .unknownSheet(let sheet): "シート「\(sheet)」が見つかりません"
            case .badCell(let cell): "セルの番地「\(cell)」が読めません(例: B5)"
            case .zip(let detail): "新しいファイルを書き出せませんでした(\(detail))"
            }
        }
    }

    /// Applies the edits to a copy of `source` written to `output`; returns each cell's value before and after.
    static func apply(_ edits: [CellEdit], to source: URL, output: URL) throws -> [CellChange] {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("xlsx-edit-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        guard run("/usr/bin/unzip", ["-q", source.path, "-d", work.path], in: work) else {
            throw Failure.unreadable(source.lastPathComponent)
        }
        let workbookURL = work.appendingPathComponent("xl/workbook.xml")
        guard let workbook = try? Data(contentsOf: workbookURL) else { throw Failure.unreadable(source.lastPathComponent) }
        let targets = (try? Data(contentsOf: work.appendingPathComponent("xl/_rels/workbook.xml.rels")))
            .map(XLSXReader.relationships) ?? [:]
        let strings = (try? Data(contentsOf: work.appendingPathComponent("xl/sharedStrings.xml"))).map(XLSXReader.sharedStrings) ?? []
        var paths: [String: String] = [:]
        for entry in XLSXReader.sheetEntries(workbook) {
            let target = targets[entry.relationship] ?? ""
            paths[entry.name] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        }

        var sheets: [String: String] = [:]   // path -> edited XML
        var changes: [CellChange] = []
        for edit in edits {
            guard let path = paths[edit.sheet] ?? (paths.count == 1 && edit.sheet.isEmpty ? paths.values.first : nil) else {
                throw Failure.unknownSheet(edit.sheet)
            }
            guard let (column, row) = address(edit.cell) else { throw Failure.badCell(edit.cell) }
            let xml = try sheets[path] ?? String(contentsOf: work.appendingPathComponent(path), encoding: .utf8)
            let before = XLSXReader.cells(Data(xml.utf8), strings: strings)
            let old = row - 1 < before.count && column < before[row - 1].count ? before[row - 1][column] : ""
            let reference = edit.cell.uppercased()
            sheets[path] = setting(cellXML(reference, edit: edit, style: styleOf(reference, in: xml)), at: reference,
                                   column: column, row: row, in: xml)
            changes.append(.init(sheet: edit.sheet, cell: reference, before: old,
                                 after: edit.formula.map { "=" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "=")) } ?? edit.value ?? ""))
        }
        for (path, xml) in sheets {
            try xml.write(to: work.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        if edits.contains(where: { $0.formula != nil }) {
            // Excel recalculates every formula when it opens the file; the old calculation chain would be stale.
            var text = String(decoding: workbook, as: UTF8.self)
            if text.contains("<calcPr") {
                text = text.replacingOccurrences(of: "<calcPr", with: "<calcPr fullCalcOnLoad=\"1\"")
                    .replacingOccurrences(of: "fullCalcOnLoad=\"1\" fullCalcOnLoad=\"1\"", with: "fullCalcOnLoad=\"1\"")
            } else {
                text = text.replacingOccurrences(of: "</workbook>", with: "<calcPr fullCalcOnLoad=\"1\"/></workbook>")
            }
            try text.write(to: workbookURL, atomically: true, encoding: .utf8)
            try? fm.removeItem(at: work.appendingPathComponent("xl/calcChain.xml"))
            for file in ["[Content_Types].xml", "xl/_rels/workbook.xml.rels"] {
                let url = work.appendingPathComponent(file)
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    let cleaned = content.replacingOccurrences(of: #"<[^<>]*calcChain[^<>]*/>"#, with: "", options: .regularExpression)
                    try cleaned.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
        guard !fm.fileExists(atPath: output.path) else { throw Failure.zip("同じ名前のファイルがあります") }
        guard run("/usr/bin/zip", ["-q", "-X", "-r", output.path, "."], in: work) else { throw Failure.zip("zip") }
        return changes
    }

    /// "B5" → (column 1, row 5).
    static func address(_ cell: String) -> (Int, Int)? {
        let letters = cell.uppercased().prefix { $0.isLetter }
        guard !letters.isEmpty, let row = Int(cell.dropFirst(letters.count)), row > 0 else { return nil }
        return (XLSXReader.column(of: String(letters)), row)
    }

    static func styleOf(_ reference: String, in xml: String) -> String? {
        guard let range = xml.range(of: #"<c r=""# + reference + #""[^>]*>"#, options: .regularExpression) else { return nil }
        let tag = String(xml[range])
        guard let style = tag.range(of: #"s="\d+""#, options: .regularExpression) else { return nil }
        return String(tag[style])
    }

    static func cellXML(_ reference: String, edit: CellEdit, style: String?) -> String {
        let s = style.map { " " + $0 } ?? ""
        if let formula = edit.formula {
            return "<c r=\"\(reference)\"\(s)><f>\(escape(formula.trimmingCharacters(in: CharacterSet(charactersIn: "="))))</f></c>"
        }
        let value = edit.value ?? ""
        if Double(value) != nil {
            return "<c r=\"\(reference)\"\(s)><v>\(value)</v></c>"
        }
        return "<c r=\"\(reference)\"\(s) t=\"inlineStr\"><is><t>\(escape(value))</t></is></c>"
    }

    /// Replaces the cell, or inserts it in column order into its row, or inserts the row in row order.
    static func setting(_ cell: String, at reference: String, column: Int, row: Int, in xml: String) -> String {
        var xml = xml
        if let range = xml.range(of: #"<c r=""# + reference + #""[^>]*?(/>|>.*?</c>)"#, options: .regularExpression) {
            xml.replaceSubrange(range, with: cell)
            return xml
        }
        if xml.contains("<sheetData/>") { xml = xml.replacingOccurrences(of: "<sheetData/>", with: "<sheetData></sheetData>") }
        if let rowRange = xml.range(of: #"<row r=""# + String(row) + #""[^>]*?(/>|>.*?</row>)"#, options: .regularExpression) {
            var rowXML = String(xml[rowRange])
            if rowXML.hasSuffix("/>") { rowXML = String(rowXML.dropLast(2)) + "></row>" }
            // Before the first cell with a greater column, else at the end of the row.
            var insertAt = rowXML.range(of: "</row>")!.lowerBound
            let pattern = try! NSRegularExpression(pattern: #"<c r="([A-Z]+)\d+""#)
            for match in pattern.matches(in: rowXML, range: NSRange(rowXML.startIndex..., in: rowXML)) {
                guard let letters = Range(match.range(at: 1), in: rowXML), let whole = Range(match.range, in: rowXML) else { continue }
                if XLSXReader.column(of: String(rowXML[letters])) > column { insertAt = whole.lowerBound; break }
            }
            rowXML.insert(contentsOf: cell, at: insertAt)
            xml.replaceSubrange(rowRange, with: rowXML)
            return xml
        }
        let newRow = "<row r=\"\(row)\">\(cell)</row>"
        let rows = try! NSRegularExpression(pattern: #"<row r="(\d+)""#)
        for match in rows.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let number = Range(match.range(at: 1), in: xml), let whole = Range(match.range, in: xml),
                  Int(xml[number]) ?? 0 > row else { continue }
            xml.insert(contentsOf: newRow, at: whole.lowerBound)
            return xml
        }
        if let end = xml.range(of: "</sheetData>") { xml.insert(contentsOf: newRow, at: end.lowerBound) }
        return xml
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The sheets as rows with cell addresses, for the model to name cells exactly ("5: A=渋谷 | B=1500").
    static func addressedText(_ source: URL, maximumRows: Int = 200) throws -> String {
        try XLSXReader.sheets(at: source).map { sheet in
            "## シート「\(sheet.name)」\n" + sheet.rows.prefix(maximumRows).enumerated().map { index, row in
                "\(index + 1): " + row.enumerated().filter { !$0.element.isEmpty }
                    .map { "\(letters(for: $0.offset))=\($0.element)" }.joined(separator: " | ")
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func letters(for column: Int) -> String {
        var n = column + 1, text = ""
        while n > 0 { n -= 1; text = String(UnicodeScalar(UInt8(65 + n % 26))) + text; n /= 26 }
        return text
    }

    private static func run(_ tool: String, _ arguments: [String], in directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
