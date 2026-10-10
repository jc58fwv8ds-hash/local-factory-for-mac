import Foundation

/// Compiler/test success is evidence, not proof that the natural-language contract is fulfilled.
public enum CanaryAcceptanceDecision {
    public static func modelResult(testsPassed: Bool, independentSpecificationPassed: Bool?) -> String {
        guard testsPassed else { return "FAIL" }
        guard let specification = independentSpecificationPassed else { return "UNVERIFIED" }
        return specification ? "PASS" : "FAIL"
    }
}
