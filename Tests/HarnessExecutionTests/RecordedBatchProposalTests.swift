import Foundation
import HarnessCore
import HarnessExecution
import Testing

struct RecordedBatchProposalTests {
    enum Probe: Error { case unavailable, unexpected }
    @Test func batchAdmissionNeverWritesAndRestartNeverRegenerates() async throws {
        let f = try Fixture(); defer { f.remove() }
        let proposals = try await f.prepare { _ in Self.response }
        #expect(proposals.count == 2)
        #expect(try String(contentsOf: f.root.appendingPathComponent("A.swift"), encoding: .utf8) == "let a = 1")
        await #expect(throws: RecordedBatchProposal.Failure.self) {
            _ = try await f.prepare { _ in throw Probe.unexpected }
        }
    }
    @Test func providerFailureAndInterruptedMarkerBlockAnotherAttempt() async throws {
        let f = try Fixture(); defer { f.remove() }
        await #expect(throws: Probe.self) { _ = try await f.prepare { _ in throw Probe.unavailable } }
        await #expect(throws: RecordedBatchProposal.Failure.self) { _ = try await f.prepare { _ in Self.response } }
        let data = try Data(contentsOf: f.records.appendingPathComponent("checkpoint.json"))
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(record["attempts"] as? Int == 1)
        #expect(record["phase"] as? String == "rejectedOrUnavailable")
    }
    @Test func invalidLastEditPreservesBothSources() async throws {
        let f = try Fixture(); defer { f.remove() }
        await #expect(throws: StructuredEditError.self) {
            _ = try await f.prepare { _ in Self.response.replacingOccurrences(of: "B.swift", with: "Secret.swift") }
        }
        #expect(try String(contentsOf: f.root.appendingPathComponent("A.swift"), encoding: .utf8) == "let a = 1")
        #expect(try String(contentsOf: f.root.appendingPathComponent("B.swift"), encoding: .utf8) == "let b = 1")
    }
    private static let response = """
    {"edits":[{"operation":"replace_exact","file":"A.swift","expected_old_text":"let a = 1","new_text":"let a = 2"},
    {"operation":"replace_exact","file":"B.swift","expected_old_text":"let b = 1","new_text":"let b = 2"}]}
    """
    private struct Fixture {
        let base: URL, root: URL, records: URL
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            root = base.appendingPathComponent("source"); records = base.appendingPathComponent("records")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "let a = 1".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
            try "let b = 1".write(to: root.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
        func prepare(_ generate: @Sendable ([String: String]) async throws -> String) async throws -> [FileChangeProposal] {
            try await RecordedBatchProposal(directory: records).prepare(root: root, files: ["A.swift", "B.swift"],
                objective: "Update both", model: "fixture", protected: [], appendOnly: [],
                maxEdits: 2, maxLines: 4, editor: RecordedProjectFileEditor(directory: base.appendingPathComponent("edits")),
                generate: generate)
        }
    }
}
