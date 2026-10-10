import CryptoKit
import Foundation

/// Phase 2 Arm B: deterministic verifier over execution evidence (no model). Concepts adapted from
/// backcheck (sequence-ordered freshness, zero/partial runs are not support, supported/contradicted/
/// inconclusive) and SWE-bench style required test sets, re-implemented natively; no OSS code copied.
/// Harness-native parts: protected-test hash contract, skipped/expected-failure rejection.
public enum DeterministicVerifier {
    public typealias Verdict = RequirementVerification.Verdict

    public struct TestResult: Codable, Equatable, Sendable {
        public let id: String
        public let status: String   // passed | failed | skipped | expectedFailure
    }
    public struct Event: Codable, Equatable, Sendable {
        public let seq: Int
        public let kind: String     // write | test | build
        public let path: String?
        public let sha256: String?
        public let command: String?
        public let exitCode: Int?
        public let fileHashes: [String: String]?
        public let results: [TestResult]?
    }
    public struct Evidence: Codable, Equatable, Sendable {
        public let protectedTests: [String: String]
        public let requiredTests: [String: [String]]
        public let regressionTests: [String]?
        public let events: [Event]
        public let claimSeq: Int
    }
    public struct Case: Codable, Sendable {
        public let taskID: String
        public let clauses: [RequirementVerification.Item]
        public let requirements: [RequirementVerification.Item]
        public let finalCode: [String: String]
        public let evidence: Evidence?
        var requiredIDs: [String] { clauses.map(\.id) + requirements.map(\.id) }
    }

    public struct ItemDecision: Codable, Equatable, Sendable {
        public let id: String
        public let final: Verdict
        public let layer: String
        public let reasons: [String]
    }
    public struct Outcome: Codable, Equatable, Sendable {
        public let arm: String
        public let final: Verdict
        public let items: [ItemDecision]
        public let global: [String]          // task-level defects (integrity, stale, partial, …)
        public let deterministicOnly: Bool   // verdict reached without using a model claim
    }

    /// Per-test status after freshness selection.
    enum TestStatus: Equatable { case passed, failed, skipped, stale, missing }

    struct Analysis {
        var global: [String] = []
        var integrityBroken = false
        var anyFreshRun = false
        var status: [String: TestStatus] = [:]
    }

    static func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func analyze(_ task: Case) -> Analysis {
        var analysis = Analysis()
        guard let evidence = task.evidence else { analysis.global.append("noEvidence: no execution evidence recorded"); return analysis }
        let current = task.finalCode.mapValues(sha)
        // Protected-test integrity (Harness-native contract; stronger than tamper heuristics).
        for (path, contract) in evidence.protectedTests.sorted(by: { $0.key < $1.key }) where current[path] != contract {
            analysis.integrityBroken = true
            analysis.global.append("protectedMutation: \(path) differs from the captured contract")
        }
        let runs = evidence.events.filter { $0.kind == "test" && $0.seq < evidence.claimSeq }.sorted { $0.seq < $1.seq }
        if runs.isEmpty { analysis.global.append("noTestRun: no test run before the completion claim") }
        // A run is fresh only if every current file matches what it ran against (sequence + content).
        func fresh(_ run: Event) -> Bool {
            guard let hashes = run.fileHashes else { return false }
            return current.allSatisfy { hashes[$0.key] == $0.value }
        }
        func consistent(_ run: Event) -> Bool {
            let results = run.results ?? []
            guard !results.isEmpty, let exit = run.exitCode else { return false }
            let failed = results.contains { $0.status == "failed" }
            return failed == (exit != 0)
        }
        for run in runs where fresh(run) && !consistent(run) {
            analysis.global.append("inconsistentReceipt: run \(run.seq) exit status disagrees with its results or has no results")
        }
        let freshRuns = runs.filter { fresh($0) && consistent($0) }
        analysis.anyFreshRun = !freshRuns.isEmpty
        if !runs.isEmpty && freshRuns.isEmpty { analysis.global.append("stale: every test run predates the final sources") }
        let required = Set(evidence.requiredTests.values.flatMap { $0 } + (evidence.regressionTests ?? []))
        for test in required.sorted() {
            if let last = freshRuns.last(where: { run in run.results?.contains { $0.id == test } == true }),
               let result = last.results?.last(where: { $0.id == test }) {
                analysis.status[test] = result.status == "passed" ? .passed : result.status == "failed" ? .failed : .skipped
            } else if runs.contains(where: { run in run.results?.contains { $0.id == test } == true }) {
                analysis.status[test] = .stale
            } else {
                analysis.status[test] = .missing
            }
        }
        let byStatus = Dictionary(grouping: analysis.status.keys.sorted(), by: { analysis.status[$0]! })
        if let skipped = byStatus[.skipped] { analysis.global.append("skipped: " + skipped.joined(separator: ", ")) }
        if let stale = byStatus[.stale] { analysis.global.append("staleTests: " + stale.joined(separator: ", ")) }
        if let missing = byStatus[.missing] { analysis.global.append("partial: required tests never ran: " + missing.joined(separator: ", ")) }
        return analysis
    }

    /// Clause verdict from its mapped tests: contradicted ⇒ VIOLATED, all passed ⇒ SATISFIED, else UNCERTAIN.
    static func clause(_ id: String, _ task: Case, _ analysis: Analysis) -> (Verdict, String) {
        let tests = task.evidence?.requiredTests[id] ?? []
        guard !tests.isEmpty else { return (.UNCERTAIN, "unmapped: no required test for this clause") }
        let statuses = tests.map { analysis.status[$0] ?? .missing }
        if statuses.contains(.failed) { return (.VIOLATED, "contradicted: fresh required test failed") }
        if statuses.allSatisfy({ $0 == .passed }) { return (.SATISFIED, "supported: all mapped tests passed on final sources") }
        return (.UNCERTAIN, "inconclusive: mapped tests stale, skipped or missing")
    }

    static func aggregate(_ items: [ItemDecision]) -> Verdict {
        items.contains { $0.final == .VIOLATED } ? .VIOLATED : items.contains { $0.final == .UNCERTAIN } || items.isEmpty ? .UNCERTAIN : .SATISFIED
    }

    /// Arm B: deterministic only.
    public static func armB(_ task: Case) -> Outcome {
        let analysis = analyze(task)
        var items = task.requiredIDs.map { id -> ItemDecision in
            let (verdict, reason) = clause(id, task, analysis)
            return .init(id: id, final: verdict, layer: "tests", reasons: [reason])
        }
        let regressionBroken = (task.evidence?.regressionTests ?? []).contains { analysis.status[$0] != .passed }
        // Fail-closed global gates: integrity, freshness, completeness, skips, regressions.
        if analysis.integrityBroken || !analysis.anyFreshRun || analysis.global.contains(where: { $0.hasPrefix("inconsistentReceipt") }) {
            items = items.map { .init(id: $0.id, final: .UNCERTAIN, layer: "global", reasons: $0.reasons + ["evidence not admissible"]) }
        } else if regressionBroken || !analysis.global.isEmpty {
            items = items.map { $0.final == .SATISFIED ? .init(id: $0.id, final: .UNCERTAIN, layer: "global", reasons: $0.reasons + analysis.global) : $0 }
        }
        return .init(arm: "B", final: aggregate(items), items: items, global: analysis.global, deterministicOnly: true)
    }

    /// Arm C: frozen Phase 1 item decisions + deterministic execution evidence.
    /// SATISFIED needs Phase 1 SATISFIED and admissible, fresh, complete, unskipped evidence.
    /// A Phase 1 VIOLATED that fresh passing mapped tests dispute becomes UNCERTAIN (conflict), never SATISFIED.
    public static func armC(_ task: Case, phase1: [VerifierAdmission.ItemDecision]?) -> Outcome {
        let analysis = analyze(task)
        let evidenceAdmissible = !analysis.integrityBroken && analysis.anyFreshRun
            && !analysis.global.contains { $0.hasPrefix("inconsistentReceipt") }
        let executionClean = evidenceAdmissible && analysis.global.isEmpty
            && (task.evidence?.regressionTests ?? []).allSatisfy { analysis.status[$0] == .passed }
        let testVerdicts = Dictionary(uniqueKeysWithValues: task.requiredIDs.map { ($0, clause($0, task, analysis)) })
        // Deterministic short-circuits: no model claim needed.
        if analysis.integrityBroken {
            let items = task.requiredIDs.map { ItemDecision(id: $0, final: .UNCERTAIN, layer: "integrity", reasons: analysis.global) }
            return .init(arm: "C", final: .UNCERTAIN, items: items, global: analysis.global, deterministicOnly: true)
        }
        if evidenceAdmissible, testVerdicts.values.contains(where: { $0.0 == .VIOLATED }) {
            let items = task.requiredIDs.map { id -> ItemDecision in
                let (verdict, reason) = testVerdicts[id]!
                return .init(id: id, final: verdict == .VIOLATED ? .VIOLATED : .UNCERTAIN, layer: "tests", reasons: [reason])
            }
            return .init(arm: "C", final: .VIOLATED, items: items, global: analysis.global, deterministicOnly: true)
        }
        let byID = Dictionary((phase1 ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = task.requiredIDs.map { id -> ItemDecision in
            guard let item = byID[id] else { return .init(id: id, final: .UNCERTAIN, layer: "claim", reasons: ["no Phase 1 decision"]) }
            let (testVerdict, testReason) = testVerdicts[id]!
            switch item.final {
            case .VIOLATED:
                if evidenceAdmissible && testVerdict == .SATISFIED {
                    return .init(id: id, final: .UNCERTAIN, layer: "conflict", reasons: item.reasons + [testReason, "static violation disputed by fresh passing tests"])
                }
                return .init(id: id, final: .VIOLATED, layer: "phase1", reasons: item.reasons)
            case .SATISFIED:
                guard executionClean else {
                    return .init(id: id, final: .UNCERTAIN, layer: "execution", reasons: analysis.global.isEmpty ? ["regression or evidence gate failed"] : analysis.global)
                }
                if testVerdict == .UNCERTAIN && testReason.hasPrefix("inconclusive") {
                    return .init(id: id, final: .UNCERTAIN, layer: "execution", reasons: [testReason])
                }
                return .init(id: id, final: .SATISFIED, layer: "all", reasons: [])
            case .UNCERTAIN:
                return .init(id: id, final: .UNCERTAIN, layer: "phase1", reasons: item.reasons)
            }
        }
        return .init(arm: "C", final: aggregate(items), items: items, global: analysis.global, deterministicOnly: false)
    }
}
