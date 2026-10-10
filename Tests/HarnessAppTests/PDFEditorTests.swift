import AppKit
import CoreText
import Foundation
import PDFKit
import Testing
@testable import HarnessApp

/// File operations stage 4 (2026-10-11): PDF operations with PDFKit, applied to a copy; the originals are never written.
struct PDFEditorTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-editor-\(UUID().uuidString)")

    func makePDF(_ name: String, pages: [String]) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            context.textPosition = CGPoint(x: 30, y: 200)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func texts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    @Test func mergeExtractRemoveReorderRotateAndStampWork() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try makePDF("a.pdf", pages: ["A1", "A2", "A3"]), b = try makePDF("b.pdf", pages: ["B1"])
        let original = try Data(contentsOf: a)
        let (merged, log) = try PDFEditor.apply([.init(op: "merge", files: [2]), .init(op: "remove", pages: "2"),
                                                .init(op: "reorder", pages: "3,1"), .init(op: "rotate", pages: "1", degrees: 90),
                                                .init(op: "watermark", text: "社外秘")], files: [a, b])
        #expect(texts(merged) == ["B1", "A1", "A3"])
        #expect(merged.page(at: 0)?.rotation == 90)
        #expect(merged.page(at: 2)?.annotations.contains { $0.contents == "社外秘" } == true)
        #expect(log.count == 5 && log[1] == "2 ページを外す")
        #expect(try Data(contentsOf: a) == original)
        let (extracted, _) = try PDFEditor.apply([.init(op: "extract", pages: "2-3")], files: [a])
        #expect(texts(extracted) == ["A2", "A3"])
        #expect(throws: PDFEditor.Failure.self) { try PDFEditor.apply([.init(op: "remove", pages: "all")], files: [a]) }
        #expect(throws: PDFEditor.Failure.self) { try PDFEditor.apply([.init(op: "extract", pages: "9")], files: [a]) }
        #expect(PDFEditor.describe([1, 2, 3, 5]) == "1〜3・5")
        #expect(PDFIntent.operations(from: #"{"operations":[{"op":"rotate","pages":"all","degrees":180}]}"#) == [.init(op: "rotate", pages: "all", degrees: 180)])
    }
}
