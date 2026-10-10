import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

struct RecordedStructuredProposalTests {
    @Test func reopenReusesAcceptedResponseAndRecordedEditorCanUndo() async throws {
        let f = try Fixture(); defer { f.remove() }
        let proposal = try await f.prepare { _ in Self.valid }
        #expect(try String(contentsOf: f.file, encoding: .utf8) == "let value = 1")
        var savedResponse = try f.state()
        savedResponse.phase = "responseSaved"
        try JSONEncoder().encode(savedResponse).write(
            to: f.records.appendingPathComponent("proposal-checkpoint.json"), options: .atomic)
        let resumed = try await f.prepare { _ in throw ProbeError.unexpectedInference }
        #expect(resumed.proposedContent == proposal.proposedContent)
        _ = try await f.prepare { _ in throw ProbeError.unexpectedInference }
        #expect(try f.state().attempts.count == 1)
        try await f.editor.apply(rootPath: f.source.path, proposal: resumed)
        #expect(try String(contentsOf: f.file, encoding: .utf8) == "let value = 2")
        await #expect(throws: RecordedStructuredProposal.Failure.changedTask) {
            try await f.prepare { _ in throw ProbeError.unexpectedInference }
        }
        try await f.editor.revert(rootPath: f.source.path, proposal: resumed)
        #expect(try String(contentsOf: f.file, encoding: .utf8) == "let value = 1")
    }

    @Test func twoRejectedResponsesSurviveRestartAndBlockThirdInference() async throws {
        let f = try Fixture(); defer { f.remove() }
        for _ in 0..<2 {
            await #expect(throws: StructuredEditError.scopeViolation) {
                try await f.prepare { _ in Self.valid.replacingOccurrences(of: "Example.swift", with: "Other.swift") }
            }
        }
        await #expect(throws: RecordedStructuredProposal.Failure.retryLimit) {
            try await f.prepare { _ in throw ProbeError.unexpectedInference }
        }
        #expect(try f.state().attempts.count == 2)
        #expect(try f.state().attempts.allSatisfy { $0.response != nil && $0.outcome == "SCOPE_OR_SCHEMA_REJECTED" })
        #expect(try String(contentsOf: f.file, encoding: .utf8) == "let value = 1")
    }

    @Test func providerFailureRetainsInputAndAllowsOneExplicitResume() async throws {
        let f = try Fixture(); defer { f.remove() }
        await #expect(throws: ProbeError.unavailable) {
            try await f.prepare { _ in throw ProbeError.unavailable }
        }
        #expect(try f.state().phase == "providerFailed")
        _ = try await f.prepare { _ in Self.valid }
        #expect(try f.state().attempts.count == 2)
        #expect(try f.state().attempts[0].response == nil)
    }

    @Test func interruptedGenerationRequiresExplicitResumeAndKeepsUnknownOutcome() async throws {
        let f = try Fixture(); defer { f.remove() }
        await #expect(throws: ProbeError.unavailable) {
            try await f.prepare { _ in throw ProbeError.unavailable }
        }
        var interrupted = try f.state()
        interrupted.phase = "generating"
        interrupted.attempts[0].outcome = "GENERATING"
        try JSONEncoder().encode(interrupted).write(
            to: f.records.appendingPathComponent("proposal-checkpoint.json"), options: .atomic)
        await #expect(throws: RecordedStructuredProposal.Failure.interrupted) {
            try await f.prepare { _ in throw ProbeError.unexpectedInference }
        }
        _ = try await RecordedStructuredProposal(directory: f.records, editor: f.editor).prepare(
            rootPath: f.source.path, target: "Example.swift", objective: "change one value",
            model: "test-provider", resumeInterrupted: true) { _ in Self.valid }
        #expect(try f.state().attempts[0].outcome == "INTERRUPTED_UNKNOWN_RESULT")
        #expect(try f.state().attempts.count == 2)
    }

    private enum ProbeError: Error { case unavailable, unexpectedInference }
    private static let valid = #"{"operation":"replace_exact","file":"Example.swift","expected_old_text":"let value = 1","new_text":"let value = 2","max_changed_lines":1}"#

    private struct Fixture: Sendable {
        let root: URL
        let source: URL
        let records: URL
        let editor: RecordedProjectFileEditor
        var file: URL { source.appendingPathComponent("Example.swift") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("StructuredProposal-\(UUID())").resolvingSymlinksInPath()
            source = root.appendingPathComponent("source")
            records = root.appendingPathComponent("records")
            editor = RecordedProjectFileEditor(directory: root.appendingPathComponent("edits"))
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("let value = 1".utf8).write(to: source.appendingPathComponent("Example.swift"))
        }
        func prepare(generate: @escaping @Sendable (String) async throws -> String) async throws -> FileChangeProposal {
            try await RecordedStructuredProposal(directory: records, editor: editor).prepare(
                rootPath: source.path, target: "Example.swift", objective: "change one value",
                model: "test-provider", generate: generate)
        }
        func state() throws -> StructuredProposalCheckpoint {
            try JSONDecoder().decode(StructuredProposalCheckpoint.self,
                from: Data(contentsOf: records.appendingPathComponent("proposal-checkpoint.json")))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
