import Foundation
import Testing
import HarnessCore
import HarnessExecution
@testable import TaskOrchestrator

let pipelineTestsEnabled = ProcessInfo.processInfo.environment["HARNESS_PIPELINE_TESTS"] == "1"

/// Phase B.1: the batch pipeline end to end with scripted model responses (no model, real isolated
/// build/test). Pins today's behaviour before the orchestrator is extracted. Serialized because the
/// pipeline keeps process-wide inference-environment state. Real sandboxed builds make these slow and load
/// the machine enough to upset timing-sensitive process tests, so they run as their own step:
/// `HARNESS_PIPELINE_TESTS=1 swift test --filter "BatchPipelineReplayTests|OrchestratedEditTests"`.
@Suite(.serialized, .enabled(if: pipelineTestsEnabled))
struct BatchPipelineReplayTests {
    actor Script {
        var plans: [String], edits: [String], prompts: [String] = []
        init(plans: [String], edits: [String]) { self.plans = plans; self.edits = edits }
        func respond(_ request: InferenceRequest) throws -> String {
            prompts.append(request.messages.map(\.content).joined(separator: "\n"))
            switch request.structuredOutput {
            case .coveragePlan?: guard !plans.isEmpty else { throw CocoaError(.featureUnsupported) }; return plans.removeFirst()
            case .structuredEditBatch?: guard !edits.isEmpty else { throw CocoaError(.featureUnsupported) }; return edits.removeFirst()
            default: throw CocoaError(.featureUnsupported)
            }
        }
        func allPrompts() -> [String] { prompts }
    }

    static let objective = "`level` は 10 以下に制限して。"
    static let meter = "public struct Meter {\n    public init() {}\n    public func level(_ v: Int) -> Int {\n        return v\n    }\n}\n"
    static let test = "import Testing\n@testable import Meter\n\n@Test func capsAtTenLevel() { #expect(Meter().level(12) == 10) }\n@Test func keepsSmallLevel() { #expect(Meter().level(3) == 3) }\n"
    static let testPath = "Tests/MeterTests/MeterAcceptanceTests.swift"
    static let sourcePath = "Sources/Meter/Meter.swift"

    let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().resolvingSymlinksInPath()

    func fixture(_ name: String, packageScope: Bool = false, mode: String? = "package") throws -> (root: URL, output: URL, cleanup: () -> Void) {
        let base = candidate.appendingPathComponent("work/b1-\(name)-\(UUID().uuidString.prefix(8))")
        let root = base.appendingPathComponent("package"), output = base.appendingPathComponent("output")
        var manifest: [String: Any] = ["objective": Self.objective, "allowedFiles": [Self.sourcePath],
            "protectedFiles": [Self.testPath], "appendOnly": [String](), "maxEdits": 2, "maxLines": 10]
        if packageScope { manifest["allowedFiles"] = nil; manifest["scopeMode"] = mode }
        var files = [
            "Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Meter\", targets: [\n    .target(name: \"Meter\"),\n    .testTarget(name: \"MeterTests\", dependencies: [\"Meter\"])\n])\n",
            Self.sourcePath: Self.meter, Self.testPath: Self.test,
            "task.json": String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self)]
        if packageScope { files["Sources/Meter/Display.swift"] = "public enum Display { public static func show(_ v: Int) -> String { \"\\(v)\" } }\n" }
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return (root.resolvingSymlinksInPath(), output, { try? FileManager.default.removeItem(at: base) })
    }

    static func plan() -> String {
        let ids = ObjectiveClauses.segment(objective).filter(\.mandatoryCandidate).map(\.clauseID)
        let item: [String: Any] = ["requirement": "Meter.level returns at most 10", "source_clause_ids": ids.isEmpty ? ["C1"] : ids,
            "relevant_symbols": ["Meter.level"], "editable_targets": [sourcePath], "read_only_evidence": [String](),
            "rationale": "level must clamp its input to 10", "coverage": "complete", "no_change_reason": NSNull()]
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["requirements": [item]]), as: UTF8.self)
    }
    static func edit(_ old: String, _ new: String, file: String = sourcePath) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["edits": [["operation": "replace_exact", "file": file,
            "expected_old_text": old, "new_text": new]]]), as: UTF8.self)
    }

    func run(_ name: String, plans: [String], edits: [String], packageScope: Bool = false, mode: String? = "package") async throws
        -> (record: [String: Any], source: String, prompts: [String]) {
        let (root, output, cleanup) = try fixture(name, packageScope: packageScope, mode: mode)
        defer { cleanup() }
        let script = Script(plans: plans, edits: edits)
        try? await PilotModelSeam.$script.withValue(.init(respond: { try await script.respond($0) })) {
            try await TaskOrchestrator.runTask(candidate: candidate, root: root, key: "b1-\(name)", model: "scripted", output: output)
        }
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("result.json"))) as! [String: Any]
        return (record, try String(contentsOf: root.appendingPathComponent(Self.sourcePath), encoding: .utf8), await script.allPrompts())
    }

    @Test func firstPassReachesRequirementGateWithoutFinalizing() async throws {
        let (record, source, prompts) = try await run("pass", plans: [Self.plan()], edits: [Self.edit("return v", "return min(v, 10)")])
        #expect(record["phase"] as? String == "testsPassedRequirementVerificationPending", "\(record)")
        #expect(record["harnessResult"] as? String == RequirementVerification.pendingResult)
        #expect(record["testsPassedHarnessResult"] as? String == "HARNESS_PASS")
        #expect(record["modelFirstPass"] as? String == "MODEL_FIRST_PASS_PASS")
        #expect(source.contains("min(v, 10)"))
        // Protected tests never reach the builder; only the independent examiner (BatchExaminerStage) may read them, as API
        // examples, after the builder has already passed them (user decision 2026-10-07).
        #expect(!prompts.filter { !$0.contains("You are an independent examiner") }.contains { $0.contains("capsAtTenLevel") })
    }

    @Test func compilerRepairRecoversAndIsNotFirstPass() async throws {
        let (record, source, _) = try await run("repair", plans: [Self.plan()],
            edits: [Self.edit("return v", "return clampToTen(v)"), Self.edit("return clampToTen(v)", "return min(v, 10)")])
        #expect(record["testsPassedHarnessResult"] as? String == "HARNESS_RECOVERED_SUCCESS", "\(record)")
        #expect(record["modelFirstPass"] as? String == "MODEL_FIRST_PASS_FAIL")
        #expect(record["modelCompilerRepair"] as? String == "MODEL_COMPILER_REPAIR_PASS")
        #expect(source.contains("min(v, 10)"))
    }

    @Test func wrongBehaviourIsReplannedOnceThenFailsAndRollsBack() async throws {
        let wrong = Self.edit("return v", "return min(v, 9)")
        let (record, source, _) = try await run("fail", plans: [Self.plan(), Self.plan()], edits: [wrong, wrong])
        #expect(record["harnessResult"] as? String == "HARNESS_FAIL", "\(record)")
        #expect((record["recoveryActions"] as? [String])?.contains("requirementReplan") == true)
        #expect(record["rollbackResult"] as? String == RollbackOutcome.ATTEMPTED_SUCCESS.rawValue, "\(record)")
        #expect(source == Self.meter)                                        // no edit left behind
    }

    @Test func hangingTestRunIsRecordedAsTestExecutionNotCompile() async throws {
        // Builds, then never returns: the isolated test run is stopped by its timeout.
        let (record, source, _) = try await run("hang", plans: [Self.plan()],
            edits: [Self.edit("return v", "while v >= 0 { _ = v }\n        return min(v, 10)")])
        #expect(record["phase"] as? String == "failed:testExecution", "\(record)")
        #expect((record["failureClass"] as? String)?.hasPrefix("Test execution") == true)
        #expect(record["rollbackResult"] as? String == RollbackOutcome.ATTEMPTED_SUCCESS.rawValue)
        #expect(source == Self.meter)
    }

    @Test func ambiguousAnchorIsRepairedOnceAndCountsAsRecovered() async throws {
        let (record, source, prompts) = try await run("anchor", plans: [Self.plan()],
            edits: [Self.edit("public", "public "), Self.edit("return v", "return min(v, 10)")])
        #expect(record["phase"] as? String == "testsPassedRequirementVerificationPending", "\(record)")
        #expect(record["testsPassedHarnessResult"] as? String == "HARNESS_RECOVERED_SUCCESS")
        #expect(record["modelFirstPass"] as? String == "MODEL_FIRST_PASS_FAIL")
        #expect((record["recoveryActions"] as? [String])?.contains("anchorRepair") == true)
        #expect(prompts.last { $0.contains("anchor did not occur exactly once") }?.contains("occurs 3 times") == true)
        #expect(source.contains("min(v, 10)"))
    }

    @Test func packageScopeMakesEveryProductionFileEditableAndKeepsTestsProtected() async throws {
        let (record, source, prompts) = try await run("package", plans: [Self.plan()],
            edits: [Self.edit("return v", "return min(v, 10)")], packageScope: true)
        #expect(record["scopeSource"] as? String == "package", "\(record)")
        #expect(record["permittedFiles"] as? [String] == ["Sources/Meter/Display.swift", Self.sourcePath])
        #expect(record["phase"] as? String == "testsPassedRequirementVerificationPending")
        #expect(record["targetDiscoveryCount"] as? Int == 0)
        #expect(source.contains("min(v, 10)"))
        #expect(!prompts.filter { !$0.contains("You are an independent examiner") }.contains { $0.contains("capsAtTenLevel") })        // protected tests still never reach the model
    }

    @Test func packageScopeIsTheDefaultAndSelectorRemainsAvailable() async throws {
        let (implicit, _, _) = try await run("default-scope", plans: [Self.plan()],
            edits: [Self.edit("return v", "return min(v, 10)")], packageScope: true, mode: nil)
        #expect(implicit["scopeSource"] as? String == "package", "\(implicit)")
        let (selector, _, _) = try await run("selector-scope", plans: [Self.plan(), Self.plan()],
            edits: [Self.edit("return v", "return min(v, 10)")], packageScope: true, mode: "selector")
        #expect(selector["scopeSource"] as? String == "contextSelector", "\(selector)")
    }

    @Test func editToProtectedTestIsRejected() async throws {
        let (record, source, _) = try await run("protected", plans: [Self.plan()],
            edits: [Self.edit("#expect(Meter().level(12) == 10)", "#expect(true)", file: Self.testPath)])
        #expect(record["harnessResult"] as? String == "HARNESS_FAIL", "\(record)")
        #expect((record["phase"] as? String)?.hasPrefix("failed:") == true)
        #expect(source == Self.meter)
    }
}
