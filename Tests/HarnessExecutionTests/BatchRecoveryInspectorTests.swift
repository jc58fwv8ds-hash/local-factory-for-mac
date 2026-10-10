import Foundation
import HarnessCore
import HarnessExecution
import Testing

struct BatchRecoveryInspectorTests {
    @Test func readsActualPartialAndCompleteWritesAcrossInspectorRestart() async throws {
        let f = try Fixture(); defer { f.remove() }
        let proposals = try await f.prepare()
        #expect(await BatchRecoveryInspector().inspect(root: f.root, checkpoint: f.checkpoint) == .unchanged)
        try await f.editor.apply(rootPath: f.root.path, proposal: proposals[0])
        #expect(await BatchRecoveryInspector().inspect(root: f.root, checkpoint: f.checkpoint) == .partiallyApplied)
        try await f.editor.apply(rootPath: f.root.path, proposal: proposals[1])
        #expect(await BatchRecoveryInspector().inspect(root: f.root, checkpoint: f.checkpoint) == .fullyApplied)
        try "user change".write(to: f.root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        #expect(await BatchRecoveryInspector().inspect(root: f.root, checkpoint: f.checkpoint) == .conflict)
        #expect(try String(contentsOf: f.root.appendingPathComponent("A.swift"), encoding: .utf8) == "user change")
    }
    @Test func wrongRootAndLegacyRecordsNeverAuthorizeRecovery() async throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try await f.prepare()
        #expect(await BatchRecoveryInspector().inspect(root: f.base, checkpoint: f.checkpoint) == .unavailable)
        try "{}".write(to: f.checkpoint, atomically: true, encoding: .utf8)
        #expect(await BatchRecoveryInspector().inspect(root: f.root, checkpoint: f.checkpoint) == .unavailable)
    }
    @Test func generatedExecutionBlockedBeforeAnyClosureRuns() {
        var executed = false
        do {
            try GeneratedCodeExecutionGate.requireRuntimeIsolation()
            executed = true
        } catch {}
        #expect(!executed)
    }
    private struct Fixture {
        let base: URL, root: URL, checkpoint: URL, editor: RecordedProjectFileEditor
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            root = base.appendingPathComponent("source")
            checkpoint = base.appendingPathComponent("proposal/checkpoint.json")
            editor = RecordedProjectFileEditor(directory: base.appendingPathComponent("edits"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "let a = 1".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
            try "let b = 1".write(to: root.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
        func prepare() async throws -> [FileChangeProposal] {
            try await RecordedBatchProposal(directory: checkpoint.deletingLastPathComponent()).prepare(
                root: root, files: ["A.swift", "B.swift"], objective: "Fixture", model: "none",
                protected: [], appendOnly: [], maxEdits: 2, maxLines: 4, editor: editor) { _ in
                """
                {"edits":[{"operation":"replace_exact","file":"A.swift","expected_old_text":"let a = 1","new_text":"let a = 2"},
                {"operation":"replace_exact","file":"B.swift","expected_old_text":"let b = 1","new_text":"let b = 2"}]}
                """
            }
        }
    }
}
