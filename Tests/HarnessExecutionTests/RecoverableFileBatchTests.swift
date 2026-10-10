import Foundation
import HarnessCore
import HarnessExecution
import Testing

struct RecoverableFileBatchTests {
    enum Injected: Error { case interruption }
    @Test func interruptedRollbackKeepsItsPersistedDirection() async throws {
        let f = try Fixture(); defer { f.remove() }; try await f.prepare()
        _ = try await f.batch.run(root: f.root, direction: .resume)
        await #expect(throws: Injected.self) {
            _ = try await f.batch.run(root: f.root, direction: .rollback) { if $0 == 1 { throw Injected.interruption } }
        }
        let recovered = try await RecoverableFileBatch(directory: f.records).run(root: f.root)
        #expect(recovered.phase == "rolledBack")
        #expect(recovered.files.allSatisfy { $0.resultingHash == $0.originalHash })
    }
    @Test func foreignChangeAfterLastWriteCannotBecomeAggregateSuccess() async throws {
        let f = try Fixture(); defer { f.remove() }; try await f.prepare()
        let file = f.root.appendingPathComponent("A.swift")
        await #expect(throws: RecoverableFileBatch.Failure.self) {
            _ = try await f.batch.run(root: f.root, direction: .resume) { index in
                if index == 1 { try "foreign".write(to: file, atomically: true, encoding: .utf8) }
            }
        }
        #expect(try f.content("A.swift") == "foreign")
    }
    @Test func restartReconcilesPendingWriteAndResumesWithoutDoubleApply() async throws {
        let f = try Fixture(); defer { f.remove() }
        try await f.prepare()
        await #expect(throws: Injected.self) {
            _ = try await f.batch.run(root: f.root, direction: .resume) { if $0 == 0 { throw Injected.interruption } }
        }
        let restarted = RecoverableFileBatch(directory: f.records)
        let observed = try await restarted.inspect(root: f.root)
        #expect(observed.files.map(\.status) == ["applied", "unapplied"])
        #expect(observed.files[0].resultingHash == observed.files[0].intendedHash)
        let finished = try await restarted.run(root: f.root, direction: .resume)
        #expect(finished.files.allSatisfy { $0.status == "applied" })
        let undone = try await restarted.run(root: f.root, direction: .rollback)
        #expect(undone.files.allSatisfy { $0.status == "unapplied" && $0.resultingHash == $0.rollbackHash })
    }
    @Test(arguments: ["partial bytes", "foreign edit"])
    func conflictNeverOverwritesEitherFile(damage: String) async throws {
        let f = try Fixture(); defer { f.remove() }; try await f.prepare()
        try damage.write(to: f.root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        await #expect(throws: RecoverableFileBatch.Failure.self) {
            _ = try await f.batch.run(root: f.root, direction: .resume)
        }
        await #expect(throws: RecoverableFileBatch.Failure.self) {
            _ = try await f.batch.run(root: f.root, direction: .rollback)
        }
        #expect(try f.content("A.swift") == damage)
        #expect(try f.content("B.swift") == "let b = 1")
    }
    @Test func stalePreparationAndProtectedTamperingBlockWrites() async throws {
        let f = try Fixture(); defer { f.remove() }
        let proposals = try await f.proposals()
        try "stale".write(to: f.root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        await #expect(throws: RecoverableFileBatch.Failure.self) {
            try await f.batch.prepare(root: f.root, proposals: proposals, allowed: ["A.swift", "B.swift"], protected: ["Acceptance.swift"])
        }
        try "let a = 1".write(to: f.root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try await f.prepare()
        try "tampered".write(to: f.root.appendingPathComponent("Acceptance.swift"), atomically: true, encoding: .utf8)
        await #expect(throws: RecoverableFileBatch.Failure.self) { _ = try await f.batch.run(root: f.root, direction: .resume) }
        #expect(try f.content("A.swift") == "let a = 1")
    }
    @Test(arguments: [RecoverableFileBatch.Direction.resume, .rollback])
    func actualSIGKILLBetweenFilesCanResumeOrRollback(direction: RecoverableFileBatch.Direction) async throws {
        let f = try Fixture(); defer { f.remove() }; try await f.prepare()
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/HarnessKernelPilot")
        let result = try await BoundedCommandRunner(timeout: .seconds(10)).run(executableURL: binary,
            arguments: ["--batch-recover", f.root.path, f.records.path, "resume", "--test-kill-after-write", "0"])
        // The child's own journal, read before `inspect` reconciles it, shows how far it got
        // (prepared = never entered run, writePending = reached the write) if it dies elsewhere.
        let journal = (try? String(contentsOf: f.records.appendingPathComponent("transaction.json"), encoding: .utf8)) ?? "-"
        let child = "exit=\(result.exitCode) duration=\(result.duration) output=\(result.output) journal=\(journal)"
        // Only the injected SIGKILL counts; an early error exit (status 1) would not test recovery.
        #expect(result.exitCode == SIGKILL, "\(child)")
        let restarted = RecoverableFileBatch(directory: f.records)
        let state = try await restarted.inspect(root: f.root)
        #expect(state.files.map(\.status) == ["applied", "unapplied"], "\(child)")
        let final = try await restarted.run(root: f.root, direction: direction)
        #expect(final.phase == (direction == .resume ? "applied" : "rolledBack"))
        #expect(try f.content("Acceptance.swift") == "let protected = true")
    }
    private struct Fixture {
        let root: URL, records: URL, base: URL, batch: RecoverableFileBatch
        init() throws {
            base = URL(fileURLWithPath: "/private/tmp/harness-batch-test-" + UUID().uuidString)
            root = base.appendingPathComponent("source"); records = base.appendingPathComponent("records")
            batch = RecoverableFileBatch(directory: records)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (p, s) in ["A.swift": "let a = 1", "B.swift": "let b = 1", "Acceptance.swift": "let protected = true"] {
                try s.write(to: root.appendingPathComponent(p), atomically: true, encoding: .utf8)
            }
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
        func content(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        func proposals() async throws -> [FileChangeProposal] {
            let editor = ProjectFileEditor()
            var result: [FileChangeProposal] = []
            for path in ["A.swift", "B.swift"] {
                let doc = try await editor.load(rootPath: root.path, relativePath: path)
                result.append(try await editor.makeProposal(document: doc, proposedContent: doc.content.replacingOccurrences(of: "1", with: "2")))
            }
            return result
        }
        func prepare() async throws {
            try await batch.prepare(root: root, proposals: proposals(), allowed: ["A.swift", "B.swift"], protected: ["Acceptance.swift"])
        }
    }
}
