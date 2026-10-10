import AppKit
import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// The spreadsheet edit and analysis with the real local model (Backburner 27B): HARNESS_LIVE_MODEL=1 swift test --filter FileOperationsLive
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HARNESS_LIVE_MODEL"] == "1"))
struct FileOperationsLiveTests {
    func store(_ folder: URL) throws -> WorkspaceStore {
        let repository = WorkspaceRepository(fileURL: folder.appendingPathComponent("workspace.json"))
        var project = HarnessProject.starter
        project.selectedModel = ModelSelection(identifier: "qwen3.8-27b-iq4xs", displayName: "27B", runtime: .backburner)
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project)]))
        return WorkspaceStore(repository: repository)
    }

    @Test func realModelAnalysisAndEdit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let csv = folder.appendingPathComponent("売上.csv")
        try "日付,店舗,商品,金額\n2026-10-01,渋谷,コーヒー,480\n2026-10-01,新宿,紅茶,520\n2026-10-02,渋谷,紅茶,520\n2026-10-02,渋谷,コーヒー,480\n2026-10-03,新宿,コーヒー,480\n"
            .write(to: csv, atomically: true, encoding: .utf8)
        let s = try store(folder)
        s.attachDocuments([csv])
        s.instruction = "店舗ごとの売上金額の合計を多い順に集計して"
        s.submitInstruction()
        var change: AnalysisChange?
        for _ in 0..<1200 {
            change = s.analysisChanges.values.first { $0.status != .running }
            if change != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("LIVE_ANALYSIS", change?.query ?? "-", change?.result?.rows ?? [], String(describing: change?.status))
        #expect(change?.result?.rows.first == ["渋谷", "1480"])

        let helper = XLSXEditorTests()
        try FileManager.default.createDirectory(at: helper.folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: helper.folder) }
        let workbook = try helper.makeWorkbook()
        let t = try store(folder.appendingPathComponent("second"))
        t.attachDocuments([workbook])
        t.instruction = "渋谷の金額を2000にして"
        t.submitInstruction()
        var edit: SpreadsheetChange?
        for _ in 0..<1200 {
            edit = t.spreadsheetChanges.values.first { $0.status != .running }
            if edit != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("LIVE_EDIT", edit?.changes ?? [], String(describing: edit?.status))
        #expect(edit?.changes == [.init(sheet: "売上", cell: "B2", before: "1500", after: "2000")])
    }
}

extension FileOperationsLiveTests {
    @Test func realModelPDFEdit() async throws {
        let helper = PDFEditorTests()
        defer { try? FileManager.default.removeItem(at: helper.folder) }
        let a = try helper.makePDF("見積書.pdf", pages: ["Page one", "Page two", "Page three"])
        let b = try helper.makePDF("別紙.pdf", pages: ["Appendix"])
        let s = try store(helper.folder)
        s.attachDocuments([a, b])
        s.instruction = "見積書の2ページ目を外して、別紙を後ろにつなげて、全ページに「社外秘」の透かしを入れて"
        s.submitInstruction()
        var change: PDFChange?
        for _ in 0..<1200 {
            change = s.pdfChanges.values.first { $0.status != .running }
            if change != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("LIVE_PDF", change?.steps ?? [], change?.pageCount ?? -1, String(describing: change?.status))
        #expect(change?.pageCount == 3)
    }
}

extension FileOperationsLiveTests {
    @Test func realModelWordEdit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-word-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("案内.docx")
        let text = NSAttributedString(string: "社内勉強会のご案内\n日時は10月20日です。\n場所は第2会議室です。")
        try text.data(from: NSRange(location: 0, length: text.length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: source)
        let s = try store(folder)
        s.attachDocuments([source])
        s.instruction = "日付を10月27日に、場所を大会議室に直して"
        s.submitInstruction()
        var change: WordChange?
        for _ in 0..<1200 {
            change = s.wordChanges.values.first { $0.status != .running }
            if change != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("LIVE_WORD", change?.changes ?? [], String(describing: change?.status))
        #expect(change?.changes.map(\.after).sorted() == ["場所は大会議室です。", "日時は10月27日です。"])
    }
}
