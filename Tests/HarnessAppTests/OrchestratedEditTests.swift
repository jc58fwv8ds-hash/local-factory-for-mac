import Foundation
import HarnessCore
import HarnessExecution
import Testing
@testable import HarnessApp
@testable import TaskOrchestrator

/// Phase B.4: the App entry behind the experimental flag. Flag off = legacy path; flag on = TaskOrchestrator on a
/// staged copy, result only through the existing review/approval step, same run record as the CLI.
@MainActor
@Suite(.serialized)
struct OrchestratedEditTests {
    let model = ModelSelection(identifier: "scripted", displayName: "Scripted", runtime: .ollama)
    let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().resolvingSymlinksInPath()
    nonisolated static let objective = "`level` は 10 以下に制限して。"
    static let source = "public struct Meter {\n    public init() {}\n    public func level(_ v: Int) -> Int {\n        return v\n    }\n}\n"
    static let files = [
        "Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Meter\", targets: [\n    .target(name: \"Meter\"),\n    .testTarget(name: \"MeterTests\", dependencies: [\"Meter\"])\n])\n",
        "Sources/Meter/Meter.swift": source,
        "Tests/MeterTests/MeterAcceptanceTests.swift": "import Testing\n@testable import Meter\n\n@Test func capsAtTenLevel() { #expect(Meter().level(12) == 10) }\n@Test func keepsSmallLevel() { #expect(Meter().level(3) == 3) }\n"]

    func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b4-project-\(UUID().uuidString)")
        for (path, content) in Self.files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root.resolvingSymlinksInPath()
    }

    @Test func onByDefaultWithTheAppsOwnCheckoutAndOffWhenDisabled() {
        let name = "b4-flags-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let inCheckout = candidate.appendingPathComponent(".build/debug/HarnessApp")
        #expect(OrchestratedRunSettings(defaults: defaults, executable: inCheckout).service != nil)       // default on
        #expect(OrchestratedRunSettings(defaults: defaults, executable: URL(fileURLWithPath: "/Applications/X.app/Contents/MacOS/X"))
            .service == nil)                                                                                  // no checkout
        defaults.set("/nonexistent-candidate", forKey: OrchestratedRunSettings.candidateKey)
        #expect(OrchestratedRunSettings(defaults: defaults, executable: inCheckout).service == nil)       // explicit path wins
        defaults.set(candidate.path, forKey: OrchestratedRunSettings.candidateKey)
        #expect(OrchestratedRunSettings(defaults: defaults, executable: nil).service != nil)
        defaults.set(false, forKey: OrchestratedRunSettings.enabledKey)
        #expect(OrchestratedRunSettings(defaults: defaults, executable: inCheckout).service == nil)       // explicitly off
    }

    @Test(arguments: [false, true])
    func sessionRoutesByFlagAndNeverWritesBeforeApproval(flagOn: Bool) async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = ProjectFileEditor()
        let legacy = CountingInference(response: #"{"content":"public struct Meter { public init() {} }\n"}"#)
        let fake = FakeOrchestrator(content: Self.source.replacingOccurrences(of: "return v", with: "return min(v, 10)"))
        let session = FileChangeSession(rootPath: root.path, model: model, editor: editor,
            gitCheckpointProvider: GitCheckpointService(fileEditor: editor), inferenceProvider: legacy,
            validationProvider: LocalProjectValidationService(), orchestrator: flagOn ? fake : nil) { _ in }
        await session.loadFiles()
        await session.select("Sources/Meter/Meter.swift")
        session.aiInstruction = Self.objective
        session.askAI()
        await session.generationTask?.value
        #expect(session.proposal != nil, "\(session.errorMessage ?? "")")
        #expect(await legacy.count == (flagOn ? 0 : 1))
        #expect(await fake.calls == (flagOn ? ["Sources/Meter/Meter.swift"] : []))
        #expect((session.orchestratedOutcome != nil) == flagOn)
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/Meter/Meter.swift"), encoding: .utf8) == Self.source)
    }

    func multiFileSession(_ root: URL, extra: [OrchestratedFileChange]) async -> FileChangeSession {
        let editor = ProjectFileEditor()
        let fake = FakeOrchestrator(content: Self.source.replacingOccurrences(of: "return v", with: "return min(v, 10)"), extra: extra)
        let session = FileChangeSession(rootPath: root.path, model: model, editor: editor,
            gitCheckpointProvider: GitCheckpointService(fileEditor: editor), inferenceProvider: CountingInference(response: "{}"),
            validationProvider: LocalProjectValidationService(), orchestrator: fake) { _ in }
        await session.loadFiles()
        await session.select("Sources/Meter/Meter.swift")
        session.aiInstruction = Self.objective
        session.askAI()
        await session.generationTask?.value
        return session
    }

    @Test func packageChangeIsReviewedAppliedAndRevertedTogether() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = "enum Limits { static let level = 10 }\n"
        let session = await multiFileSession(root, extra: [.init(relativePath: "Sources/Meter/Limits.swift", original: nil, proposed: limits)])
        #expect(session.proposal?.relativePath == "Sources/Meter/Meter.swift", "\(session.errorMessage ?? "")")
        #expect(session.relatedProposals.map(\.relativePath) == ["Sources/Meter/Limits.swift"])
        let limitsURL = root.appendingPathComponent("Sources/Meter/Limits.swift")
        #expect(!FileManager.default.fileExists(atPath: limitsURL.path))   // nothing written before approval
        #expect(await session.applyProposal() != nil, "\(session.errorMessage ?? "")")
        #expect(try String(contentsOf: limitsURL, encoding: .utf8) == limits)
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/Meter/Meter.swift"), encoding: .utf8).contains("min(v, 10)"))
        #expect(await session.revertAppliedProposal() != nil, "\(session.errorMessage ?? "")")
        #expect(!FileManager.default.fileExists(atPath: limitsURL.path))
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/Meter/Meter.swift"), encoding: .utf8) == Self.source)
    }

    @Test func aRelatedFileThatCannotApplyLeavesTheProjectUnchanged() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        // The related file already exists on disk, so its creation is refused after the selected file applied.
        try "// existing\n".write(to: root.appendingPathComponent("Sources/Meter/Zone.swift"), atomically: true, encoding: .utf8)
        let session = await multiFileSession(root, extra: [.init(relativePath: "Sources/Meter/Zone.swift", original: "// before\n",
                                                                 proposed: "enum Zone {}\n")])
        #expect(session.relatedProposals.count == 1, "\(session.errorMessage ?? "")")
        #expect(await session.applyProposal() == nil)
        #expect(session.errorMessage != nil)
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/Meter/Meter.swift"), encoding: .utf8) == Self.source)
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/Meter/Zone.swift"), encoding: .utf8) == "// existing\n")
    }

    @Test func changedFilesAreCollectedSelectedFirstAndTestsIgnored() throws {
        let source = try project(), staged = try project()
        defer { for url in [source, staged] { try? FileManager.default.removeItem(at: url) } }
        try "enum A {}\n".write(to: staged.appendingPathComponent("Sources/Meter/A.swift"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: staged.appendingPathComponent("Sources/Meter/Meter.swift"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: staged.appendingPathComponent("Tests/MeterTests/MeterAcceptanceTests.swift"), atomically: true, encoding: .utf8)
        let changes = try OrchestratedEditService.changes(staged: staged, source: source, selected: "Sources/Meter/Meter.swift")
        #expect(changes.map(\.relativePath) == ["Sources/Meter/Meter.swift", "Sources/Meter/A.swift"])
        #expect(changes[1].original == nil && changes[0].original == Self.source)
    }

    /// Real sandboxed builds: runs only in the pipeline step (`HARNESS_PIPELINE_TESTS=1`), see BatchPipelineReplayTests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_PIPELINE_TESTS"] == "1"))
    func serviceRunsThePipelineOnAStagedCopyWithTheCLIRecord() async throws {
        let root = try project()
        let outputs = FileManager.default.temporaryDirectory.appendingPathComponent("b4-out-\(UUID().uuidString)")
        let cliRoot = candidate.appendingPathComponent("work/b4-cli-\(UUID().uuidString.prefix(8).lowercased())")
        var staged: URL?
        defer { for url in [root, outputs, cliRoot] + (staged.map { [$0] } ?? []) { try? FileManager.default.removeItem(at: url) } }
        let service = OrchestratedEditService(candidate: candidate, outputRoot: outputs)
        let outcome = try await PilotModelSeam.$script.withValue(Scripted.script()) {
            try await service.proposeEdit(rootPath: root.path, relativePath: "Sources/Meter/Meter.swift",
                                          instruction: Self.objective, model: model)
        }
        let key = outcome.runRecord.deletingLastPathComponent().lastPathComponent
        staged = candidate.appendingPathComponent("work/\(key)")
        #expect(outcome.changes.first?.relativePath == "Sources/Meter/Meter.swift")
        #expect(outcome.changes.first?.proposed.contains("min(v, 10)") == true)
        #expect(outcome.testsPassedResult == "HARNESS_PASS")
        #expect(outcome.harnessResult == RequirementVerification.pendingResult)
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/Meter/Meter.swift"), encoding: .utf8) == Self.source)

        // The CLI path on the same project and task manifest produces the same record shape.
        _ = try OrchestratedEditService.stage(root, into: cliRoot)
        try FileManager.default.copyItem(at: staged!.appendingPathComponent("task.json"), to: cliRoot.appendingPathComponent("task.json"))
        let cliOutput = outputs.appendingPathComponent("cli")
        try await PilotModelSeam.$script.withValue(Scripted.script()) {
            try await TaskOrchestrator.runTask(candidate: candidate, root: cliRoot.resolvingSymlinksInPath(), key: "b4-cli",
                                               model: model.identifier, output: cliOutput)
        }
        let app = try JSONSerialization.jsonObject(with: Data(contentsOf: outcome.runRecord)) as! [String: Any]
        let cli = try JSONSerialization.jsonObject(with: Data(contentsOf: cliOutput.appendingPathComponent("result.json"))) as! [String: Any]
        #expect(Set(app.keys) == Set(cli.keys), "\(Set(app.keys).symmetricDifference(Set(cli.keys)))")
        for field in ["phase", "harnessResult", "testsPassedHarnessResult", "modelFirstPass", "scopeSource", "permittedFiles",
                      "LOCAL_AUTONOMOUS_VERIFIER", "verificationMode", "objective"] {
            #expect(String(describing: app[field] ?? "nil") == String(describing: cli[field] ?? "nil"), "\(field)")
        }
        let journal = try #require(try OrchestratorLedger.replay(directory: outcome.runRecord.deletingLastPathComponent().appendingPathComponent("kernel")))
        #expect(journal.pauseReason == app["phase"] as? String)
    }
}

private actor CountingInference: ModelInferenceProvider {
    let response: String
    private(set) var count = 0
    init(response: String) { self.response = response }
    func events(for request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        count += 1
        let stream = AsyncThrowingStream<String, Error>.makeStream()
        stream.continuation.yield(response)
        stream.continuation.finish()
        return stream.stream
    }
}

private actor FakeOrchestrator: OrchestratedEditing {
    let content: String
    let extra: [OrchestratedFileChange]
    private(set) var calls: [String] = []
    init(content: String, extra: [OrchestratedFileChange] = []) { self.content = content; self.extra = extra }
    func proposeEdit(rootPath: String, relativePath: String, instruction: String,
                     model: ModelSelection) async throws -> OrchestratedEditOutcome {
        calls.append(relativePath)
        let original = try String(contentsOf: URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath), encoding: .utf8)
        return .init(changes: [.init(relativePath: relativePath, original: original, proposed: content)] + extra,
                     runRecord: URL(fileURLWithPath: "/dev/null"),
                     testsPassedResult: "HARNESS_PASS", harnessResult: RequirementVerification.pendingResult)
    }
}

/// Correct coverage plan + one correct edit, answered by structured-output kind.
private enum Scripted {
    static func script() -> PilotModelSeam.Script {
        .init { request in
            switch request.structuredOutput {
            case .coveragePlan?:
                let ids = ObjectiveClauses.segment(OrchestratedEditTests.objective).filter(\.mandatoryCandidate).map(\.clauseID)
                let item: [String: Any] = ["requirement": "Meter.level returns at most 10", "source_clause_ids": ids.isEmpty ? ["C1"] : ids,
                    "relevant_symbols": ["Meter.level"], "editable_targets": ["Sources/Meter/Meter.swift"],
                    "read_only_evidence": [String](), "rationale": "level must clamp its input to 10",
                    "coverage": "complete", "no_change_reason": NSNull()]
                return String(decoding: try JSONSerialization.data(withJSONObject: ["requirements": [item]]), as: UTF8.self)
            case .structuredEditBatch?:
                return String(decoding: try JSONSerialization.data(withJSONObject: ["edits": [["operation": "replace_exact",
                    "file": "Sources/Meter/Meter.swift", "expected_old_text": "return v", "new_text": "return min(v, 10)"]]]), as: UTF8.self)
            default: throw CocoaError(.featureUnsupported)
            }
        }
    }
}

struct OrchestratedRoutingTests {
    @Test func backburnerModelIsRoutedByPrefixAndOllamaIsUnchanged() {
        #expect(OrchestratedEditService.routedModel(ModelSelection(identifier: "qwen3.8-27b-iq4xs", displayName: "B",
                                                                   runtime: .backburner)) == "backburner:qwen3.8-27b-iq4xs")
        #expect(OrchestratedEditService.routedModel(ModelSelection(identifier: "qwen3.8:27b", displayName: "O",
                                                                   runtime: .ollama)) == "qwen3.8:27b")
    }
}
