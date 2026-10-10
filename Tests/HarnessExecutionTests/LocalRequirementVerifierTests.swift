import Foundation
import Testing
@testable import HarnessExecution

struct LocalRequirementVerifierTests {
    func request() throws -> RequirementVerification.Request {
        try JSONDecoder().decode(RequirementVerification.Request.self, from: Data(#"{"taskID":"blind","objective":"Return count","clauses":[{"id":"C1","text":"Return count"}],"requirements":[],"productionDiff":"+ func count() -> Int { 1 }","finalCode":{"Sources/A.swift":"func count() -> Int { 1 }"},"builderModel":"BUILDER_SECRET"}"#.utf8))
    }
    @Test func promptExcludesIdentityAndReferenceLabels() throws {
        let prompt = try LocalRequirementVerifier.prompt(request())
        #expect(!prompt.contains("BUILDER_SECRET"))
        #expect(!prompt.contains("referenceLabel"))
        #expect(prompt.contains("Return count"))
    }
    @Test func identityIsRuntimeOwnedAndSelfReviewCannotPass() throws {
        let r = try request()
        let response = try JSONDecoder().decode(LocalRequirementVerifier.Response.self,
            from: Data(#"{"items":[{"id":"C1","verdict":"SATISFIED","evidence":"returns count","file":"Sources/A.swift","symbol":"count"}]}"#.utf8))
        let report = try LocalRequirementVerifier.report(response, request: r, model: r.builderModel)
        #expect(RequirementVerification.decide(report, for: r).outcome == .INVALID_REPORT)
        let independent = try LocalRequirementVerifier.report(response, request: r, model: "other-model")
        #expect(RequirementVerification.decide(independent, for: r).outcome == .REQUIREMENTS_SATISFIED)
    }
    @Test func inventedEvidenceAndMissingItemsFailClosed() throws {
        let bad = try JSONDecoder().decode(LocalRequirementVerifier.Response.self,
            from: Data(#"{"items":[{"id":"C1","verdict":"SATISFIED","evidence":"claimed","file":"Tests/Hidden.swift","symbol":"answer"}]}"#.utf8))
        #expect(throws: (any Error).self) { try LocalRequirementVerifier.report(bad, request: request(), model: "other") }
        let empty = try JSONDecoder().decode(LocalRequirementVerifier.Response.self, from: Data(#"{"items":[]}"#.utf8))
        #expect(throws: (any Error).self) { try LocalRequirementVerifier.report(empty, request: request(), model: "other") }
    }
}
