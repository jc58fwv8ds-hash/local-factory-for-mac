import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// File operations stage 3 (2026-10-11): cells are edited into a new .xlsx; styles and the original file stay as they were.
struct XLSXEditorTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xlsx-editor-\(UUID().uuidString)")

    func makeWorkbook() throws -> URL {
        let parts = folder.appendingPathComponent("parts")
        let files: [String: String] = [
            "[Content_Types].xml": #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/xl/calcChain.xml" ContentType="x"/></Types>"#,
            "xl/workbook.xml": #"<workbook xmlns:r="r"><sheets><sheet name="売上" sheetId="1" r:id="rId1"/></sheets><calcPr calcId="1"/></workbook>"#,
            "xl/_rels/workbook.xml.rels": #"<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId9" Target="calcChain.xml"/></Relationships>"#,
            "xl/calcChain.xml": "<calcChain/>",
            "xl/sharedStrings.xml": #"<sst><si><t>店舗</t></si><si><t>金額</t></si><si><t>渋谷</t></si></sst>"#,
            "xl/worksheets/sheet1.xml": #"<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" s="3"><v>1500</v></c></row></sheetData></worksheet>"#,
        ]
        for (path, text) in files {
            let url = parts.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let xlsx = folder.appendingPathComponent("売上.xlsx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = parts
        zip.arguments = ["-q", "-r", xlsx.path, "."]
        try zip.run(); zip.waitUntilExit()
        return xlsx
    }

    @Test func cellsAreEditedIntoANewFileKeepingStylesAndTheOriginal() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try makeWorkbook()
        let original = try Data(contentsOf: source)
        let output = folder.appendingPathComponent("売上_編集済み.xlsx")
        let changes = try XLSXEditor.apply([
            .init(sheet: "売上", cell: "B2", value: "1800"),            // existing cell, keeps style s="3"
            .init(sheet: "売上", cell: "C2", value: "新宿店"),            // new cell in an existing row
            .init(sheet: "売上", cell: "B4", formula: "=SUM(B2:B3)"),   // new row with a formula
        ], to: source, output: output)
        #expect(changes.map(\.before) == ["1500", "", ""])
        #expect(changes.map(\.after) == ["1800", "新宿店", "=SUM(B2:B3)"])
        #expect(try Data(contentsOf: source) == original)            // the original is untouched
        let sheets = try XLSXReader.sheets(at: output)
        #expect(sheets.first?.rows[1] == ["渋谷", "1800", "新宿店"])
        let check = folder.appendingPathComponent("check")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", output.path, "-d", check.path]
        try unzip.run(); unzip.waitUntilExit()
        let sheet = try String(contentsOf: check.appendingPathComponent("xl/worksheets/sheet1.xml"), encoding: .utf8)
        #expect(sheet.contains(#"<c r="B2" s="3"><v>1800</v></c>"#))
        #expect(sheet.contains(#"<row r="4"><c r="B4"><f>SUM(B2:B3)</f></c></row>"#))
        let workbook = try String(contentsOf: check.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)
        #expect(workbook.contains("fullCalcOnLoad=\"1\""))
        #expect(!FileManager.default.fileExists(atPath: check.appendingPathComponent("xl/calcChain.xml").path))
        // An existing output is never overwritten.
        #expect(throws: XLSXEditor.Failure.self) { try XLSXEditor.apply([.init(sheet: "売上", cell: "A1", value: "x")], to: source, output: output) }
        #expect(try XLSXEditor.addressedText(source).contains("2: A=渋谷 | B=1500"))
        #expect(SpreadsheetIntent.edits(from: #"{"edits":[{"sheet":"売上","cell":"B2","value":2000}]}"#)
            == [.init(sheet: "売上", cell: "B2", value: "2000")])
    }
}

/// The chat flow: an attached workbook and 「〜にして」 become a card; apply writes 「〜_編集済み.xlsx」 next to it.
@MainActor
struct SpreadsheetChatTests {
    struct EditModel: ModelInferenceProvider {
        func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield(#"{"edits": [{"sheet": "売上", "cell": "B2", "value": "1650"}]}"#); $0.finish() }
        }
    }

    @Test func anAttachedWorkbookEditBecomesACardAndANewFile() async throws {
        let helper = XLSXEditorTests()
        try FileManager.default.createDirectory(at: helper.folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: helper.folder) }
        let source = try helper.makeWorkbook()
        let repository = WorkspaceRepository(fileURL: helper.folder.appendingPathComponent("workspace.json"))
        var project = HarnessProject.starter
        project.selectedModel = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project)]))
        let store = WorkspaceStore(repository: repository, inferenceProvider: EditModel())
        store.attachDocuments([source])
        store.instruction = "渋谷の金額を1割増しにして"
        store.submitInstruction()
        var change: SpreadsheetChange?
        for _ in 0..<200 {
            change = store.spreadsheetChanges.values.first { $0.status != .running }
            if change != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let ready = try #require(change)
        #expect(ready.status == .ready && ready.changes == [.init(sheet: "売上", cell: "B2", before: "1500", after: "1650")])
        store.applySpreadsheetChange(ready)
        guard case .applied(let output) = ready.status else { Issue.record("not applied: \(ready.status)"); return }
        #expect(output.lastPathComponent == "売上_編集済み.xlsx")
        #expect(try XLSXReader.sheets(at: output).first?.rows[1] == ["渋谷", "1650"])
        #expect(try XLSXReader.sheets(at: source).first?.rows[1] == ["渋谷", "1500"])
    }
}
