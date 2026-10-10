import Foundation
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks of the Phase 1 fail-closed admission gate.
/// Protected property: a model's SATISFIED claim never becomes SATISFIED unless every
/// deterministic evidence check passes; anything unproven is UNCERTAIN.
struct VerifierAdmissionTests {
    typealias Claim = VerifierAdmission.Claim
    let file = "Sources/Net/RetryPolicy.swift"
    let source = """
    struct RetryPolicy {
        var maximumAttempts: Int { 3 }

        func shouldRetry(attempt: Int,
                         failed: Bool) -> Bool {
            if !failed { return false }
            return attempt <= 3
        }

        func delay(for attempt: Int) -> Double {
            return min(Double(attempt) * 0.5, 4.0)
        }
    }
    """
    let testFile = "Tests/NetTests/RetryPolicyTests.swift"
    let testSource = "#expect(RetryPolicy().shouldRetry(attempt: 1, failed: true) == true) // attempt < 3"

    func request(_ clauses: [String]) -> RequirementVerification.Request {
        .init(taskID: "synthetic", objective: clauses.joined(separator: " "),
              clauses: clauses.enumerated().map { .init(id: "C\($0.offset + 1)", text: $0.element) },
              requirements: [], productionDiff: "", finalCode: [file: source, testFile: testSource], builderModel: "builder")
    }
    func claim(_ status: RequirementVerification.Verdict = .SATISFIED, id: String = "C1", file: String? = nil,
               symbol: String, quote: String) -> Claim {
        .init(id: id, claimedStatus: status, file: file ?? self.file, symbol: symbol, exactSupportingQuote: quote, rationale: "r")
    }
    func admit(_ clause: String, _ claims: [Claim], protected: Set<String> = []) -> VerifierAdmission.Outcome {
        VerifierAdmission.admit(claims: claims, request: request([clause]), protectedPaths: protected)
    }

    let failureOnly = "失敗したときだけ `shouldRetry` で再試行し、成功時は false を返して。"

    @Test func validEvidenceIsAdmittedWithQualifiedSymbol() {
        let outcome = admit(failureOnly, [claim(symbol: "RetryPolicy.shouldRetry(attempt:failed:)", quote: "if !failed {  return false }")])
        #expect(outcome.final == .SATISFIED)
        #expect(outcome.items[0].canonicalSymbol == "shouldRetry")
        #expect(outcome.items[0].passed == ["fileExists", "symbolExists", "quoteExists", "quoteInScope", "relevant",
                                            "noContradiction", "edgeAnchors"])
    }

    @Test func symbolCanonicalization() {
        #expect(VerifierSymbols.canonicalForm("RetryPolicy.maximumAttempts").name == "maximumAttempts")
        #expect(VerifierSymbols.canonicalForm("shouldRetry(attempt:failed:)").name == "shouldRetry")
        #expect(VerifierSymbols.canonicalForm("RetryPolicy.delay(_:)") == ("delay", "RetryPolicy"))
        #expect(VerifierSymbols.resolve("RetryPolicy.delay(for:)", file: file, sources: [file: source]).exists)
        #expect(!VerifierSymbols.resolve("Backoff.delay(for:)", file: file, sources: [file: source]).exists)
        #expect(!VerifierSymbols.resolve("retryIfNeeded", file: file, sources: [file: source]).exists)
    }

    @Test func nonexistentQuoteIsUncertain() {
        let outcome = admit(failureOnly, [claim(symbol: "shouldRetry", quote: "if !failed { return nil }")])
        #expect(outcome.final == .UNCERTAIN)
    }

    @Test func nonexistentOrMisqualifiedSymbolIsUncertain() {
        for symbol in ["retryIfNeeded", "Backoff.shouldRetry", "shouldRetry(", "   "] {
            #expect(admit(failureOnly, [claim(symbol: symbol, quote: "if !failed { return false }")]).final == .UNCERTAIN)
        }
    }

    @Test func quoteOutsideClaimedSymbolScopeIsUncertain() {
        let outcome = admit(failureOnly, [claim(symbol: "delay", quote: "if !failed { return false }")])
        #expect(outcome.final == .UNCERTAIN)
    }

    @Test func correctQuoteForWrongClauseIsUncertain() {
        let outcome = admit(failureOnly, [claim(symbol: "delay", quote: "return min(Double(attempt) * 0.5, 4.0)")])
        #expect(outcome.final == .UNCERTAIN)
        #expect(outcome.items[0].reasons.first?.contains("not related") == true)
    }

    @Test func missingEdgeConditionIsUncertain() {
        let clause = "`shouldRetry` は失敗したときに再試行し、接続が nil のときは false を返して。"
        let outcome = admit(clause, [claim(symbol: "shouldRetry", quote: "if !failed { return false }")])
        #expect(outcome.final == .UNCERTAIN)
        #expect(outcome.items[0].reasons.first?.contains("nil") == true)
    }

    @Test func deterministicContradictionIsViolatedEvenWhenModelClaimsSatisfied() {
        let clause = "`shouldRetry` は attempt が 3 未満のときだけ true を返して。"
        let outcome = admit(clause, [claim(symbol: "shouldRetry", quote: "return attempt <= 3")])
        #expect(outcome.final == .VIOLATED)
        #expect(admit("`shouldRetry` は attempt が 3 以下なら再試行して。",
                      [claim(symbol: "shouldRetry", quote: "return attempt <= 3")]).items[0].reasons.isEmpty)
    }

    @Test func unsupportedSemanticRequirementIsUncertain() {
        for clause in ["ユーザーにとって自然な挙動にして。", "エラー以外の場合は今までどおりにして。", "Keep it feeling responsive."] {
            #expect(admit(clause, [claim(symbol: "shouldRetry", quote: "if !failed { return false }")]).final == .UNCERTAIN)
        }
    }

    @Test func protectedTestEvidenceIsRejected() {
        let fromTest = admit(failureOnly, [claim(file: testFile, symbol: "shouldRetry", quote: "shouldRetry(attempt: 1, failed: true)")])
        #expect(fromTest.final == .UNCERTAIN)
        let protected = admit(failureOnly, [claim(symbol: "shouldRetry", quote: "if !failed { return false }")], protected: [file])
        #expect(protected.final == .UNCERTAIN)
    }

    @Test func claimsWithoutSatisfiedProofNeverPassTheTask() {
        let good = claim(symbol: "shouldRetry", quote: "if !failed { return false }")
        let twoClauses = request([failureOnly, "ユーザーにとって自然な挙動にして。"])
        #expect(VerifierAdmission.admit(claims: [good], request: twoClauses).final == .UNCERTAIN)            // missing claim
        #expect(VerifierAdmission.admit(claims: [good, good], request: request([failureOnly])).final == .UNCERTAIN) // duplicate
        #expect(admit(failureOnly, [claim(.UNCERTAIN, symbol: "shouldRetry", quote: "if !failed { return false }")]).final == .UNCERTAIN)
        #expect(admit(failureOnly, [claim(.VIOLATED, symbol: "shouldRetry", quote: "return attempt <= 3")]).final == .VIOLATED)
        #expect(admit(failureOnly, [claim(.VIOLATED, symbol: "shouldRetry", quote: "not in the code at all")]).final == .UNCERTAIN)
    }

    /// Exhaustive adversarial sweep: every line of the production file as quote, with every
    /// symbol spelling, can never make a contradicted or edge-missing clause SATISFIED.
    @Test func noClaimCanAdmitAViolatedClause() {
        let violated = ["`shouldRetry` は attempt が 3 未満のときだけ true を返して。",
                        "`shouldRetry` は接続が nil のときは false を返して。",
                        "`delay` は 10 秒を超えないようにして。",
                        "エラー以外の場合は今までどおりにして。"]
        let quotes = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 6 }
        let symbols = ["RetryPolicy", "maximumAttempts", "shouldRetry", "RetryPolicy.shouldRetry(attempt:failed:)", "delay", "attempt", "failed"]
        for clause in violated {
            for quote in quotes {
                for symbol in symbols {
                    let outcome = admit(clause, [claim(symbol: symbol, quote: quote)])
                    #expect(outcome.final != .SATISFIED, "\(clause) | \(symbol) | \(quote)")
                }
            }
        }
    }

    @Test func promptNeverContainsTestOrProtectedSources() throws {
        let prompt = try VerifierAdmission.prompt(request([failureOnly]))
        #expect(!prompt.contains("#expect(") && !prompt.contains(testFile))
        #expect(prompt.contains("shouldRetry(attempt: Int"))
        let hidden = try VerifierAdmission.prompt(request([failureOnly]), protectedPaths: [file])
        #expect(!hidden.contains("maximumAttempts"))
        #expect(try JSONSerialization.jsonObject(with: Data(VerifierAdmission.claimSchema.utf8)) is [String: Any])
    }
}
