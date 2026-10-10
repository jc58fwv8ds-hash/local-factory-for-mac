import AppKit
import Foundation
import PDFKit

/// PDF operations from the chat (file operations stage 4, 2026-10-11; docs/design/FILE-OPERATIONS.md), with PDFKit only.
/// The model lists operations; this applies them in order to a copy and writes a NEW file. The originals are never written.
enum PDFEditor {
    struct Operation: Codable, Equatable, Sendable {
        /// merge, extract, remove, reorder, rotate, watermark, note, fill
        var op: String
        /// Attached file numbers (1-based) to merge, in order.
        var files: [Int]?
        /// Page list like "1-3,5" or "all" (1-based), or a new order like "3,1,2" for reorder.
        var pages: String?
        var degrees: Int?
        var text: String?
        var page: Int?
        /// Form field name → value.
        var fields: [String: String]?
    }

    enum Failure: LocalizedError {
        case unreadable(String), badPages(String), unknown(String), empty, write
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "「\(name)」を開けませんでした"
            case .badPages(let pages): "ページの指定「\(pages)」が読めません(例: 1-3,5)"
            case .unknown(let op): "「\(op)」という操作はできません"
            case .empty: "ページが残りません"
            case .write: "新しい PDF を書き出せませんでした"
            }
        }
    }

    /// Applies the operations starting from the first attached file; returns the result and a line per operation.
    static func apply(_ operations: [Operation], files: [URL]) throws -> (PDFDocument, [String]) {
        guard let first = files.first, let document = PDFDocument(url: first) else {
            throw Failure.unreadable(files.first?.lastPathComponent ?? "PDF")
        }
        var log: [String] = []
        for operation in operations {
            switch operation.op {
            case "merge":
                let indices = (operation.files ?? Array(2...max(2, files.count))).filter { $0 >= 2 && $0 <= files.count }
                for index in indices {
                    guard let other = PDFDocument(url: files[index - 1]) else { throw Failure.unreadable(files[index - 1].lastPathComponent) }
                    for page in 0..<other.pageCount {
                        if let copy = other.page(at: page)?.copy() as? PDFPage { document.insert(copy, at: document.pageCount) }
                    }
                    log.append("「\(files[index - 1].lastPathComponent)」の \(other.pageCount) ページを後ろにつなげる")
                }
            case "extract", "remove":
                let chosen = try pages(operation.pages ?? "all", count: document.pageCount)
                let keep = operation.op == "extract" ? chosen : (1...document.pageCount).filter { !chosen.contains($0) }
                guard !keep.isEmpty else { throw Failure.empty }
                for index in (1...document.pageCount).reversed() where !keep.contains(index) { document.removePage(at: index - 1) }
                log.append(operation.op == "extract" ? "\(describe(chosen)) ページだけを残す" : "\(describe(chosen)) ページを外す")
            case "reorder":
                let order = try pages(operation.pages ?? "", count: document.pageCount, keepOrder: true)
                let all = (0..<document.pageCount).compactMap { document.page(at: $0) }
                let sequence = order + (1...all.count).filter { !order.contains($0) }
                for index in (0..<document.pageCount).reversed() { document.removePage(at: index) }
                for (position, number) in sequence.enumerated() { document.insert(all[number - 1], at: position) }
                log.append("ページの順を \(order.map(String.init).joined(separator: "・")) に並べ替える")
            case "rotate":
                let degrees = ((operation.degrees ?? 90) % 360 + 360) % 360
                guard degrees % 90 == 0 else { throw Failure.unknown("回転 \(degrees)°") }
                let chosen = try pages(operation.pages ?? "all", count: document.pageCount)
                for number in chosen { document.page(at: number - 1).map { $0.rotation = ($0.rotation + degrees) % 360 } }
                log.append("\(describe(chosen)) ページを \(degrees)° 回転")
            case "watermark":
                let text = operation.text ?? ""
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    let box = CGRect(x: bounds.minX, y: bounds.midY - 40, width: bounds.width, height: 80)
                    let stamp = PDFAnnotation(bounds: box, forType: .freeText, withProperties: nil)
                    stamp.contents = text
                    stamp.font = NSFont.boldSystemFont(ofSize: 48)
                    stamp.fontColor = NSColor.gray.withAlphaComponent(0.35)
                    stamp.color = .clear
                    stamp.alignment = .center
                    page.addAnnotation(stamp)
                }
                log.append("全ページに透かし「\(text)」")
            case "note":
                let number = max(1, min(operation.page ?? 1, document.pageCount))
                if let page = document.page(at: number - 1) {
                    let bounds = page.bounds(for: .mediaBox)
                    let note = PDFAnnotation(bounds: CGRect(x: bounds.maxX - 60, y: bounds.maxY - 60, width: 24, height: 24),
                                             forType: .text, withProperties: nil)
                    note.contents = operation.text ?? ""
                    page.addAnnotation(note)
                }
                log.append("\(number) ページに注釈「\(operation.text ?? "")」")
            case "fill":
                var filled: [String] = []
                for index in 0..<document.pageCount {
                    for annotation in document.page(at: index)?.annotations ?? [] {
                        guard let name = annotation.fieldName, let value = operation.fields?[name] else { continue }
                        annotation.widgetStringValue = value
                        filled.append("\(name)=\(value)")
                    }
                }
                log.append(filled.isEmpty ? "記入できる欄が見つかりませんでした" : "フォームに記入: " + filled.joined(separator: "、"))
            default:
                throw Failure.unknown(operation.op)
            }
        }
        guard document.pageCount > 0 else { throw Failure.empty }
        return (document, log)
    }

    /// "1-3,5" → [1,2,3,5]; "all" → every page. With keepOrder, the order as written ("3,1,2").
    static func pages(_ text: String, count: Int, keepOrder: Bool = false) throws -> [Int] {
        let spec = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "、", with: ",").replacingOccurrences(of: "〜", with: "-")
        if spec.isEmpty || ["all", "全部", "すべて"].contains(spec.lowercased()) { return Array(1...max(count, 1)) }
        var result: [Int] = []
        for part in spec.split(separator: ",") {
            let bounds = part.split(separator: "-").map { Int($0) }
            guard let low = bounds.first ?? nil else { throw Failure.badPages(text) }
            let high = bounds.count > 1 ? (bounds[1] ?? count) : low
            guard low >= 1, high <= count, low <= high else { throw Failure.badPages(text) }
            result += Array(low...high)
        }
        return keepOrder ? result : Array(Set(result)).sorted()
    }

    static func describe(_ pages: [Int]) -> String {
        var parts: [String] = [], start = pages.first, previous = pages.first
        for page in pages.dropFirst() + [Int.min] {
            if let p = previous, page == p + 1 { previous = page; continue }
            if let s = start, let p = previous { parts.append(s == p ? "\(s)" : "\(s)〜\(p)") }
            start = page; previous = page
        }
        return parts.joined(separator: "・")
    }

    static func outputURL(for source: URL) -> URL {
        let folder = source.deletingLastPathComponent(), base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(base)_編集済み.pdf"), n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)_編集済み \(n).pdf"); n += 1
        }
        return candidate
    }
}
