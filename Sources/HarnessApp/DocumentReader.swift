import AppKit
import Foundation
import HarnessCore
import PDFKit
import UniformTypeIdentifiers

/// Reads documents attached in the chat into plain text (file operations stage 1, 2026-10-09; docs/design/FILE-OPERATIONS.md).
/// PDF through PDFKit, Word / RTF through the system's own importer, Excel by reading the sheet XML inside the .xlsx
/// (no third-party code), CSV and plain text as they are. Everything stays on this Mac.
enum DocumentReader {
    enum Failure: LocalizedError {
        case unsupported(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let name): "「\(name)」は読めない種類のファイルです(PDF・Word・Excel・CSV・テキストに対応)"
            case .unreadable(let name): "「\(name)」を読めませんでした"
            }
        }
    }

    static let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data
    static let docx = UTType("org.openxmlformats.wordprocessingml.document") ?? .data
    static let doc = UTType("com.microsoft.word.doc") ?? .data
    static let contentTypes: [UTType] = [.pdf, docx, doc, .rtf, xlsx, .commaSeparatedText, .plainText]
    /// Rows read per sheet; a larger sheet is cut with a note (the model's context is the limit, not the reader).
    static let maximumRowsPerSheet = 400

    static func isDocument(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return contentTypes.contains { type.conforms(to: $0) }
    }

    static func read(_ url: URL) throws -> DocumentText {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw Failure.unreadable(name) }
            let pages = (0..<pdf.pageCount).map { index in
                "[\(index + 1) ページ]\n" + (pdf.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let text = pages.joined(separator: "\n\n")
            let hasText = !(0..<pdf.pageCount).allSatisfy { (pdf.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return DocumentText(displayName: name, kind: "PDF",
                                summary: "\(pdf.pageCount) ページ" + (hasText ? "" : "・文字のない画像の PDF(文字認識は未対応)"),
                                text: hasText ? text : "")
        case "docx", "doc", "rtf":
            let type: NSAttributedString.DocumentType = ext == "docx" ? .officeOpenXML : ext == "doc" ? .docFormat : .rtf
            guard let attributed = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) else {
                throw Failure.unreadable(name)
            }
            let text = attributed.string
            return DocumentText(displayName: name, kind: ext == "rtf" ? "リッチテキスト" : "Word",
                                summary: "\(text.count) 文字", text: text)
        case "xlsx":
            let sheets = try XLSXReader.sheets(at: url)
            let text = sheets.map { sheet in
                let rows = sheet.rows.prefix(maximumRowsPerSheet).map { $0.joined(separator: "\t") }
                let cut = sheet.rows.count > maximumRowsPerSheet ? "\n…(\(sheet.rows.count) 行のうち \(maximumRowsPerSheet) 行まで)" : ""
                return "## シート「\(sheet.name)」\n" + rows.joined(separator: "\n") + cut
            }.joined(separator: "\n\n")
            return DocumentText(displayName: name, kind: "Excel",
                                summary: "シート \(sheets.count) 枚・\(sheets.reduce(0) { $0 + $1.rows.count }) 行", text: text)
        case "csv", "tsv", "txt", "md":
            guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .shiftJIS)) else {
                throw Failure.unreadable(name)
            }
            return DocumentText(displayName: name, kind: ext == "csv" || ext == "tsv" ? "表(CSV)" : "テキスト",
                                summary: "\(text.components(separatedBy: "\n").count) 行", text: text)
        default:
            throw Failure.unsupported(name)
        }
    }
}

/// Minimal .xlsx reader: the workbook is a zip of XML parts; the sheet cells are read with their shared strings.
/// Values only (formulas show their last computed value, as Excel saved it).
enum XLSXReader {
    struct Sheet: Equatable { let name: String; let rows: [[String]] }

    static func sheets(at url: URL) throws -> [Sheet] {
        func part(_ path: String) -> Data? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", url.path, path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }
        guard let workbook = part("xl/workbook.xml") else { throw DocumentReader.Failure.unreadable(url.lastPathComponent) }
        let strings = part("xl/sharedStrings.xml").map(sharedStrings) ?? []
        let targets = part("xl/_rels/workbook.xml.rels").map(relationships) ?? [:]
        return sheetEntries(workbook).compactMap { entry in
            let target = targets[entry.relationship] ?? ""
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let data = part(path) else { return nil }
            return Sheet(name: entry.name, rows: cells(data, strings: strings))
        }
    }

    static func sheetEntries(_ data: Data) -> [(name: String, relationship: String)] {
        let collector = ElementCollector(element: "sheet")
        collector.parse(data)
        return collector.attributes.map { ($0["name"] ?? "", $0["r:id"] ?? "") }
    }

    static func relationships(_ data: Data) -> [String: String] {
        let collector = ElementCollector(element: "Relationship")
        collector.parse(data)
        return Dictionary(collector.attributes.map { ($0["Id"] ?? "", $0["Target"] ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    static func sharedStrings(_ data: Data) -> [String] {
        let parser = SharedStringParser()
        parser.parse(data)
        return parser.strings
    }

    /// Rows of cell values; a missing cell keeps its column empty so the columns line up.
    static func cells(_ data: Data, strings: [String]) -> [[String]] {
        let parser = SheetParser(strings: strings)
        parser.parse(data)
        return parser.rows
    }

    /// "B12" → 1 (zero-based column).
    static func column(of reference: String) -> Int {
        reference.prefix { $0.isLetter }.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }
}

private class XMLCollector: NSObject, XMLParserDelegate {
    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
}

private final class ElementCollector: XMLCollector {
    let element: String
    var attributes: [[String: String]] = []
    init(element: String) { self.element = element }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if name == element { self.attributes.append(attributes) }
    }
}

private final class SharedStringParser: XMLCollector {
    var strings: [String] = []
    private var current: String?, inText = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if name == "si" { current = "" }
        if name == "t" { inText = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current? += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "si" { strings.append(current ?? ""); current = nil }
    }
}

private final class SheetParser: XMLCollector {
    let strings: [String]
    var rows: [[String]] = []
    private var row: [String] = [], column = 0, type = "", value = "", inValue = false
    init(strings: [String]) { self.strings = strings }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch name {
        case "row": row = []
        case "c": column = attributes["r"].map(XLSXReader.column) ?? row.count; type = attributes["t"] ?? ""; value = ""
        case "v", "t": inValue = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { value += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": inValue = false
        case "c":
            let text = type == "s" ? (Int(value).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? "") : value
            if column >= 0 {
                while row.count < column { row.append("") }
                if row.count == column { row.append(text) } else { row[column] = text }
            }
        case "row": rows.append(row)
        default: break
        }
    }
}
