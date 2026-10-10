import Testing
@testable import HarnessExecution

struct ContextSelectorTests {
    @Test func unrelatedProjectUsesSymbolsAndDependenciesWithoutFilenameAllowlist() {
        let paths = [
            "Sources/DiaryMac/EntryScreen.swift",
            "Sources/DiaryMac/IncomingEnvelope.swift",
            "Sources/DiaryPhone/EntryScreen.swift",
            "Sources/Unrelated/GenericView.swift",
            "Tests/DiaryMacTests/IncomingEnvelopeTests.swift"
        ]
        let evidence: [ContextFileEvidence] = [
            .init(path: paths[0], source: "import AppKit\nText(\"受信した録音の状態\")\nIncomingEnvelope()"),
            .init(path: paths[1], source: "struct IncomingEnvelope { let status = \"Macで録音を受信\" }"),
            .init(path: paths[2], source: "Text(\"録音を送信\")"),
            .init(path: paths[3], source: "Text(\"その他の設定\")"),
            .init(path: paths[4], source: "func testIncomingEnvelopeStatus() {}")
        ]
        let selected = ContextSelector.select(objective: "Macに届いた録音の状態を表示したい",
            paths: paths, evidence: evidence)
        #expect(selected.files.first == paths[0])
        #expect(selected.files.contains(paths[1]))
        #expect(!selected.files.contains(paths[3]))
        #expect(selected.tests.first == paths[4])
    }

    @Test func explicitlyNamedTypeIsNotCutByRelatedFileScore() {
        let paths = ["Sources/Notes/NoteDraft.swift", "Sources/Notes/NoteDraftArchive.swift",
                     "Sources/Notes/Archive.swift", "Sources/Notes/SyncStatus.swift"]
        let evidence: [ContextFileEvidence] = [
            .init(path: paths[0], source: "struct NoteDraft { var status = \"sync pending\" }"),
            .init(path: paths[1], source: "struct NoteDraftArchive { func load() -> NoteDraft? { nil } }"),
            .init(path: paths[2], source: "struct Archive {}"),
            .init(path: paths[3], source: "enum SyncStatus { case pending }")
        ]
        let selected = ContextSelector.select(
            objective: "同期状態を扱えるように NoteDraft にプロパティを足し、NoteDraftArchive にも取得メソッドを追加して",
            paths: paths, evidence: evidence)
        // Explicitly named files lead the selection; "archive" occurs only inside a
        // longer identifier, so Archive.swift is not treated as explicitly named.
        #expect(Set(selected.files.prefix(2)) == [paths[0], paths[1]])
    }
}
