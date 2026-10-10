import HarnessCore
import Testing

struct CanaryAcceptanceDecisionTests {
    @Test func testsNeverSubstituteForSpecification() {
        #expect(CanaryAcceptanceDecision.modelResult(testsPassed: true, independentSpecificationPassed: nil) == "UNVERIFIED")
        #expect(CanaryAcceptanceDecision.modelResult(testsPassed: true, independentSpecificationPassed: false) == "FAIL")
        #expect(CanaryAcceptanceDecision.modelResult(testsPassed: false, independentSpecificationPassed: true) == "FAIL")
        #expect(CanaryAcceptanceDecision.modelResult(testsPassed: true, independentSpecificationPassed: true) == "PASS")
    }
}
