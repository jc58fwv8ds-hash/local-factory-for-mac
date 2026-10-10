import Foundation
import HarnessCore
import HarnessExecution

extension TaskOrchestrator {
    /// A failure during which the environment was invalidated (stall, degraded generation,
    /// system sleep) is ENVIRONMENT_INVALID: excluded from capability rates, kept as an
    /// operational-reliability event; the capability-side class is preserved for audit.
    static func classifyEnvironment(_ record: BatchRunRecord) {
        let environment = InferenceEnvironment.shared
        let slept = environment.sleptSeconds
        guard let reason = environment.invalidation
                ?? (slept > InferenceHealth.sleepToleranceSeconds ? String(format: "systemSleep(%.0fs)", slept) : nil),
              record["failureClass"] as? String != "ENVIRONMENT_INVALID" else { return }
        record["capabilityFailureClassIfValid"] = record["failureClass"] ?? "none"
        record["failureClass"] = "ENVIRONMENT_INVALID"; record["harnessResult"] = "ENVIRONMENT_INVALID"
        record["modelResult"] = "UNVERIFIED"; record["modelFirstPass"] = "UNVERIFIED (ENVIRONMENT_INVALID)"
        record["capabilityValid"] = false; record["environmentInvalidReason"] = reason
        record["promotionEligible"] = false
    }

    /// Rollback execution truth: an attempted rollback is never downgraded by later bookkeeping.
    static func noteRollback(_ record: BatchRunRecord, _ detail: String) {
        let current = (record["rollbackResult"] as? String).flatMap(RollbackOutcome.init(rawValue:))
        record["rollbackResult"] = RollbackOutcome.merge(current, RollbackOutcome(detail: detail)).rawValue
        record.append("rollbackEvents", detail)
    }

    package static func json<T: Encodable>(_ value: T?) -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let value, let data = try? encoder.encode(value) else { return NSNull() }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? NSNull()
    }
}
