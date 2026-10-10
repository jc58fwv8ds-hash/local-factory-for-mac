import Foundation
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks of Phase 2 Arm B (deterministic) and Arm C (hybrid).
/// Protected property: stale, partial, skipped, tampered or inconsistent evidence never yields SATISFIED.
struct DeterministicVerifierTests {
    typealias V = DeterministicVerifier
    let source = "Sources/Lib/Meter.swift", test = "Tests/LibTests/MeterAcceptanceTests.swift"
    let good = "struct Meter { func level(_ v: Int) -> Int { min(max(v, 0), 10) } }"
    let testCode = "@Test func clamps() { #expect(Meter().level(11) == 10) }"

    func hashes(_ files: [String: String]) -> [String: String] { files.mapValues(V.sha) }
    func run(_ seq: Int, _ files: [String: String], _ results: [(String, String)], exit: Int? = nil) -> V.Event {
        let failed = results.contains { $0.1 == "failed" }
        return .init(seq: seq, kind: "test", path: nil, sha256: nil, command: "swift test", exitCode: exit ?? (failed ? 1 : 0),
                     fileHashes: hashes(files), results: results.map { .init(id: $0.0, status: $0.1) })
    }
    func task(final: [String: String]? = nil, protected: [String: String]? = nil, required: [String: [String]] = ["C1": ["Meter/clamps"]],
              regression: [String] = [], events: [V.Event], claim: Int = 99) -> V.Case {
        let files = final ?? [source: good, test: testCode]
        return .init(taskID: "t", clauses: [.init(id: "C1", text: "clamp to 0...10")], requirements: [], finalCode: files,
                     evidence: .init(protectedTests: protected ?? [test: V.sha(testCode)], requiredTests: required,
                                     regressionTests: regression, events: events, claimSeq: claim))
    }
    var files: [String: String] { [source: good, test: testCode] }
    func phase1(_ verdict: RequirementVerification.Verdict) -> [VerifierAdmission.ItemDecision] {
        [.init(id: "C1", claimed: verdict, final: verdict, canonicalSymbol: "level", passed: [], reasons: [])]
    }

    @Test func freshCompletePassingEvidenceIsSupported() {
        let t = task(events: [run(5, files, [("Meter/clamps", "passed")])])
        #expect(V.armB(t).final == .SATISFIED)
        #expect(V.armC(t, phase1: phase1(.SATISFIED)).final == .SATISFIED)
    }

    @Test func sourceModifiedAfterGreenIsStale() {
        let before = [source: "struct Meter { func level(_ v: Int) -> Int { v } }", test: testCode]
        let t = task(events: [run(5, before, [("Meter/clamps", "passed")]),
                              .init(seq: 6, kind: "write", path: source, sha256: V.sha(good), command: nil, exitCode: nil, fileHashes: nil, results: nil)])
        #expect(V.armB(t).final == .UNCERTAIN)
        #expect(V.armB(t).global.contains { $0.hasPrefix("stale") })
        #expect(V.armC(t, phase1: phase1(.SATISFIED)).final == .UNCERTAIN)
    }

    @Test func runAfterTheClaimDoesNotCount() {
        let t = task(events: [run(120, files, [("Meter/clamps", "passed")])], claim: 100)
        #expect(V.armB(t).final == .UNCERTAIN)
    }

    @Test func partialSubsetRunIsInconclusive() {
        let t = task(required: ["C1": ["Meter/clamps", "Meter/lowerBound"]], events: [run(5, files, [("Meter/clamps", "passed")])])
        #expect(V.armB(t).final == .UNCERTAIN)
        #expect(V.armC(t, phase1: phase1(.SATISFIED)).final == .UNCERTAIN)
    }

    @Test func skippedOrExpectedFailureIsNotGreen() {
        for status in ["skipped", "expectedFailure"] {
            let t = task(events: [run(5, files, [("Meter/clamps", status)])])
            #expect(V.armB(t).final == .UNCERTAIN)
            #expect(V.armC(t, phase1: phase1(.SATISFIED)).final == .UNCERTAIN)
        }
    }

    @Test func protectedTestMutationBlocksEverything() {
        let weakened = "@Test func clamps() { #expect(true) }"
        let mutated = [source: good, test: weakened]
        let t = task(final: mutated, events: [run(5, mutated, [("Meter/clamps", "passed")])])
        #expect(V.armB(t).final == .UNCERTAIN)
        let c = V.armC(t, phase1: phase1(.SATISFIED))
        #expect(c.final == .UNCERTAIN && c.deterministicOnly)
    }

    @Test func freshFailureIsContradictionWithoutModel() {
        let t = task(events: [run(5, files, [("Meter/clamps", "failed")])])
        #expect(V.armB(t).final == .VIOLATED)
        let c = V.armC(t, phase1: phase1(.SATISFIED))
        #expect(c.final == .VIOLATED && c.deterministicOnly)
    }

    @Test func staleFailureIsNotContradiction() {
        let old = [source: "struct Meter {}", test: testCode]
        let t = task(events: [run(5, old, [("Meter/clamps", "failed")])])
        #expect(V.armB(t).final == .UNCERTAIN)
    }

    @Test func inconsistentOrEmptyReceiptIsNotEvidence() {
        #expect(V.armB(task(events: [run(5, files, [("Meter/clamps", "failed")], exit: 0)])).final == .UNCERTAIN)
        #expect(V.armB(task(events: [run(5, files, [])])).final == .UNCERTAIN)
        #expect(V.armB(task(events: [])).final == .UNCERTAIN)
        let none = V.Case(taskID: "t", clauses: [.init(id: "C1", text: "x")], requirements: [], finalCode: files, evidence: nil)
        #expect(V.armB(none).final == .UNCERTAIN && V.armC(none, phase1: phase1(.SATISFIED)).final == .UNCERTAIN)
    }

    @Test func unmappedClauseIsUnsupportedForArmB() {
        let t = task(required: [:], events: [run(5, files, [("Meter/clamps", "passed")])])
        #expect(V.armB(t).final == .UNCERTAIN)
    }

    @Test func regressionFailureBlocksSatisfied() {
        let t = task(regression: ["Meter/old"], events: [run(5, files, [("Meter/clamps", "passed"), ("Meter/old", "failed")])])
        #expect(V.armB(t).final != .SATISFIED)
        #expect(V.armC(t, phase1: phase1(.SATISFIED)).final != .SATISFIED)
    }

    @Test func staticViolationDisputedByFreshTestsBecomesUncertain() {
        let t = task(events: [run(5, files, [("Meter/clamps", "passed")])])
        #expect(V.armC(t, phase1: phase1(.VIOLATED)).final == .UNCERTAIN)
        let unmapped = task(required: [:], events: [run(5, files, [("Meter/clamps", "passed")])])
        #expect(V.armC(unmapped, phase1: phase1(.VIOLATED)).final == .VIOLATED)
    }

    /// Hybrid never admits SATISFIED unless Phase 1 admitted it, for every evidence variant.
    @Test func hybridNeverExceedsPhase1() {
        let variants: [V.Case] = [
            task(events: [run(5, files, [("Meter/clamps", "passed")])]),
            task(events: [run(5, files, [("Meter/clamps", "failed")])]),
            task(events: [run(5, [source: "x", test: testCode], [("Meter/clamps", "passed")])]),
            task(required: [:], events: [run(5, files, [("Meter/clamps", "passed")])]),
            task(events: [])]
        for variant in variants {
            for verdict in [RequirementVerification.Verdict.UNCERTAIN, .VIOLATED] {
                #expect(V.armC(variant, phase1: phase1(verdict)).final != .SATISFIED)
            }
            #expect(V.armC(variant, phase1: nil).final != .SATISFIED)
        }
    }
}
