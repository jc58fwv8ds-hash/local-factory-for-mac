import Foundation
import HarnessKernel
import Testing

struct KernelRoutingPolicyTests {
    @Test func toolsAndLocalDoNotRequireExternalAuthentication() {
        #expect(decide(.deterministic).route == .tools)
        #expect(decide(.simpleAnalysis, local: true).route == .local)
        #expect(decide(.focusedEdit, local: true).route == .blocked)
    }

    @Test func subscriptionGateCannotBeBypassedByModelAvailability() {
        #expect(decide(.focusedEdit, sol: true, astra: true).route == .blocked)
        #expect(decide(.crossBoundary, sol: true, astra: true).route == .blocked)
    }

    @Test func noSilentUpgradeOrDowngrade() {
        #expect(decide(.focusedEdit, verified: true, sol: true).route == .sol)
        #expect(decide(.focusedEdit, verified: true, astra: true).route == .blocked)
        #expect(decide(.crossBoundary, verified: true, sol: true).route == .blocked)
        #expect(decide(.crossBoundary, verified: true, astra: true).route == .astra)
    }

    @Test func riskReviewAndRepeatedFailureAreExplicit() throws {
        let risk = decide(.deterministic, risk: true)
        #expect(risk.independentReviewRequired)
        #expect(!decide(.deterministic).independentReviewRequired)
        let stopped = decide(.focusedEdit, verified: true, sol: true, failures: 2)
        #expect(stopped.route == .blocked)
        #expect(stopped.independentReviewRequired)
        let encoded = try JSONEncoder().encode(stopped)
        #expect(try JSONDecoder().decode(KernelRoutingPolicy.Decision.self, from: encoded) == stopped)
    }

    private func decide(_ work: KernelRoutingPolicy.Work, local: Bool = false,
                        verified: Bool = false, sol: Bool = false, astra: Bool = false,
                        risk: Bool = false, failures: Int = 0) -> KernelRoutingPolicy.Decision {
        KernelRoutingPolicy.decide(work: work, localCompatible: local,
            subscriptionDispatchVerified: verified, solAvailable: sol,
            astraAvailable: astra, materialRisk: risk, repeatedFailures: failures)
    }
}
