import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// File operations stage 3 (2026-10-11): DuckDB computes the numbers; the model's SQL can read only the loaded tables.
struct SpreadsheetAnalysisTests {
    @Test func aQueryRunsOnTheSheetsAndFileAccessIsLocked() throws {
        guard SpreadsheetAnalysis.duckdbPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let helper = XLSXEditorTests()
        try FileManager.default.createDirectory(at: helper.folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: helper.folder) }
        let csv = helper.folder.appendingPathComponent("来店.csv")
        try "店舗,人数\n渋谷,120\n新宿,80\n渋谷,30\n".write(to: csv, atomically: true, encoding: .utf8)
        let tables = try SpreadsheetAnalysis.tables(from: [try helper.makeWorkbook(), csv])
        #expect(tables.map(\.name) == ["t1", "t2"] && tables[1].columns == ["店舗", "人数"])
        #expect(SpreadsheetAnalysis.schema(tables).contains("表 t2(来店.csv、3 行): 列 \"店舗\", \"人数\""))
        let result = try SpreadsheetAnalysis.run(#"SELECT "店舗", SUM("人数") AS 合計 FROM t2 GROUP BY 1 ORDER BY 2 DESC"#, tables: tables)
        #expect(result.columns == ["店舗", "合計"])
        #expect(result.rows == [["渋谷", "150"], ["新宿", "80"]])
        // No file outside the loaded tables can be read or written by the query.
        #expect(throws: SpreadsheetAnalysis.Failure.self) {
            try SpreadsheetAnalysis.run("SELECT * FROM read_csv('/etc/hosts')", tables: tables)
        }
        #expect(SpreadsheetAnalysis.sql(from: "```sql\nSELECT 1;\n```") == "SELECT 1")
        #expect(SpreadsheetAnalysis.sql(from: "DROP TABLE t1") == nil)
        #expect(SpreadsheetAnalysis.csvFields(#"a,"b,c","d""e""#) == ["a", "b,c", #"d"e"#])
    }
}

@MainActor
struct AnalysisChatTests {
    struct SQLModel: ModelInferenceProvider {
        func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield("```sql\nSELECT \"店舗\", SUM(\"人数\") AS 合計 FROM t1 GROUP BY 1 ORDER BY 2 DESC\n```"); $0.finish() }
        }
    }

    @Test func aQuestionAboutAnAttachedTableBecomesAResultCard() async throws {
        guard SpreadsheetAnalysis.duckdbPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let csv = folder.appendingPathComponent("来店.csv")
        try "店舗,人数\n渋谷,120\n新宿,80\n渋谷,30\n".write(to: csv, atomically: true, encoding: .utf8)
        let repository = WorkspaceRepository(fileURL: folder.appendingPathComponent("workspace.json"))
        var project = HarnessProject.starter
        project.selectedModel = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project)]))
        let store = WorkspaceStore(repository: repository, inferenceProvider: SQLModel())
        store.attachDocuments([csv])
        store.instruction = "店舗ごとの来店人数の合計を多い順に"
        store.submitInstruction()
        var change: AnalysisChange?
        for _ in 0..<200 {
            change = store.analysisChanges.values.first { $0.status != .running }
            if change != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(change?.status == .ready)
        #expect(change?.result?.rows == [["渋谷", "150"], ["新宿", "80"]])
    }
}
