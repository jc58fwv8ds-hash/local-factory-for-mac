import Foundation
import HarnessExecution
import Testing

struct ClaudeFallbackGateTests {
    @Test func onlyFreshSubscriptionSafeExhaustionCanPass() {
        let now = Date(timeIntervalSince1970: 1_000)
        let ready = ClaudeFallbackEvidence(codexQuotaExhausted: true, claudeAuthMethod: "claude.ai",
            claudeSubscription: "pro", extraUsageOff: true, providerOverridesAbsent: true,
            commandCompatible: true, taskScopeApproved: true, observedAt: now)
        #expect(ClaudeFallbackGate.blockingReasons(ready, now: now).isEmpty)
        #expect(!ClaudeFallbackGate.blockingReasons(ready, now: now.addingTimeInterval(301)).isEmpty)
    }

    @Test func currentNonExhaustedAndUnknownBillingStateFailClosed() {
        let now = Date(timeIntervalSince1970: 1_000)
        let blocked = ClaudeFallbackEvidence(codexQuotaExhausted: false, claudeAuthMethod: "claude.ai",
            claudeSubscription: "pro", extraUsageOff: false, providerOverridesAbsent: false,
            commandCompatible: false, taskScopeApproved: true, observedAt: now)
        let reasons = ClaudeFallbackGate.blockingReasons(blocked, now: now)
        #expect(reasons.count == 4)
    }
}
