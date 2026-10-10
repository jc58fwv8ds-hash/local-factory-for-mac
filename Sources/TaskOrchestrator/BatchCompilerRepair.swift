import Foundation
import HarnessCore
import HarnessExecution

/// I/O half of the bounded compiler-guided repair: one fast compile, receipt-based
/// diagnostics, and at most one recorded repair proposal applied as its own transaction.
enum BatchCompilerRepair {
    enum Stop: Error { case notRepairable(String), repairDidNotCompile }

    struct CompileFailure {
        let diagnostics: [CompilerRepair.Diagnostic]
        let failureClass: CompilerRepair.FailureClass
    }

    /// nil = compiled. A compile failure is only recognised from an intact receipt
    /// (exit status, no integrity violation); anything else is rethrown unchanged.
    static func compile(_ isolated: IsolatedPackageExecution, evidence: URL, root: URL) async throws -> CompileFailure? {
        do {
            _ = try await GeneratedCodeExecutionGate.executePackage(isolated, operation: .build, evidence: evidence)
            return nil
        } catch {
            let receipts = (try? FileManager.default.contentsOfDirectory(at: evidence,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = receipts.filter { $0.lastPathComponent.hasPrefix("build-") && $0.pathExtension == "json" }
                .max { a, b in
                    let x = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let y = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return x < y
                }
            guard let newest,
                  let receipt = try? JSONSerialization.jsonObject(with: Data(contentsOf: newest)) as? [String: Any],
                  let exit = receipt["exitStatus"] as? Int, exit != 0,
                  receipt["integrityViolation"] as? Bool == false,
                  let output = receipt["output"] as? String else { throw error }
            let diagnostics = CompilerRepair.diagnostics(output: output, root: root)
            guard !diagnostics.isEmpty else { throw error }
            return CompileFailure(diagnostics: diagnostics, failureClass: CompilerRepair.classify(diagnostics))
        }
    }

    /// One repair proposal from minimal context, re-validated and applied as a new
    /// transaction whose precondition is the post-first-pass content.
    static func attempt(root: URL, output: URL, model: String, objective: String,
                        firstPass: [FileChangeProposal], failure: CompileFailure,
                        permitted: [String], protected: Set<String>, maxEdits: Int, maxLines: Int,
                        editor: RecordedProjectFileEditor, transaction: RecoverableFileBatch,
                        budget: inout RequirementCoverage.Budget, record: BatchRunRecord? = nil) async throws -> [FileChangeProposal] {
        let files = CompilerRepair.repairFiles(diagnostics: failure.diagnostics,
            firstPass: firstPass.map(\.relativePath), editable: Set(permitted))
        var packageSources: [String: String] = [:]
        for path in permitted where path.hasPrefix("Sources/") {
            packageSources[path] = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let declarations = CompilerRepair.typeDeclarations(diagnostics: failure.diagnostics, sources: packageSources)
        func propose(_ name: String, note: String?) async throws -> [FileChangeProposal] {
            try await RecordedBatchProposal(directory: output.appendingPathComponent(name)).prepare(root: root, files: files,
                objective: objective, model: model, protected: protected, appendOnly: [], maxEdits: maxEdits, maxLines: maxLines,
                editor: editor) { current in
                let prompt = CompilerRepair.prompt(objective: objective, proposals: firstPass, current: current,
                    diagnostics: failure.diagnostics, maxEdits: maxEdits, maxLines: maxLines, declarations: declarations)
                    + (note.map { "\n" + $0 } ?? "")
                return try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                    messages: [.init(role: .user, content: prompt)], maximumOutputTokens: 2048, structuredOutput: .structuredEditBatch))
            }
        }
        let proposals: [FileChangeProposal]
        do {
            proposals = try await propose("repair-proposal", note: nil)
        } catch StructuredEditError.ambiguousAnchor {
            // Same anchor repair as the proposal stage (shared single-use budget): one re-proposal with the match counts.
            let directory = output.appendingPathComponent("repair-proposal")
            guard let batch = BatchProposalStage.savedBatch(in: directory),
                  let originals = (try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("checkpoint.json")))
                      as? [String: Any])?["originals"] as? [String: String],
                  case let report = batch.anchorReport(originals: originals), !report.isEmpty,
                  budget.consume(.anchorRepair) else { throw StructuredEditError.ambiguousAnchor }
            record?.append("recoveryActions", "anchorRepair(compilerRepair)"); try record?.save()
            proposals = try await propose("repair-proposal-anchor", note: "Your previous edits were rejected because an anchor did not occur exactly once:\n"
                + report.joined(separator: "\n") + "\nReturn the complete corrected edit list.")
        }
        try await transaction.prepare(root: root, proposals: proposals, allowed: Set(permitted), protected: protected)
        _ = try await transaction.run(root: root, direction: .resume)
        return proposals
    }

    enum TestOutcome { case passed, verificationFailed(VerificationAdjudication.Verdict) }

    /// A failing test run from an intact receipt is a verification failure (requirements
    /// unmet); anything else (integrity, isolation) is rethrown and never replanned.
    static func test(_ isolated: IsolatedPackageExecution, evidence: URL) async throws -> TestOutcome {
        do {
            _ = try await GeneratedCodeExecutionGate.executePackage(isolated, operation: .test, evidence: evidence)
            return .passed
        } catch {
            let receipts = (try? FileManager.default.contentsOfDirectory(at: evidence,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = receipts.filter { $0.lastPathComponent.hasPrefix("test-") && $0.pathExtension == "json" && !$0.lastPathComponent.contains(".adjudicated.") }
                .max { a, b in
                    let x = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let y = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return x < y
                }
            guard let newest,
                  let receipt = try? JSONSerialization.jsonObject(with: Data(contentsOf: newest)) as? [String: Any],
                  let exit = receipt["exitStatus"] as? Int, exit != 0,
                  receipt["integrityViolation"] as? Bool == false else { throw error }
            let verdict = VerificationAdjudication.classify(output: receipt["output"] as? String ?? "")
            return .verificationFailed(verdict)
        }
    }

    static func encode(_ diagnostics: [CompilerRepair.Diagnostic]) -> [[String: Any]] {
        diagnostics.prefix(12).map { ["path": $0.path, "line": $0.line, "column": $0.column, "message": $0.message] }
    }
}
