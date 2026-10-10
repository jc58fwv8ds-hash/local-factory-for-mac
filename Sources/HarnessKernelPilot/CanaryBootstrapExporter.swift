import Foundation
import CryptoKit
import HarnessExecution

/// Local-only, bounded handoff preparation. Never authorizes or invokes a provider.
enum CanaryBootstrapExporter {
    enum Failure: Error { case scope, unverified, invalidEvidence }
    static func run(arguments: [String]) async throws {
        guard arguments.count == 3 else { throw Failure.scope }
        let root = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        guard root.lastPathComponent == "dogfood-candidate" else { throw Failure.scope }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/Dogfood")
        var tasks: [[String: Any]] = []
        for key in ["logic-004", "schema-005"] {
            let directory = support.appendingPathComponent(key)
            let verificationURL = directory.appendingPathComponent("verification.json")
            let verificationData = try bounded(verificationURL)
            guard let verification = try JSONSerialization.jsonObject(with: verificationData) as? [String: Any],
                  verification["status"] as? String == "verified-package",
                  let path = verification["validationRun"] as? String else { throw Failure.unverified }
            let run = URL(fileURLWithPath: path).standardizedFileURL
            guard run.deletingLastPathComponent() == directory.appendingPathComponent("validation"),
                  run.resolvingSymlinksInPath() == run else { throw Failure.scope }
            let status = try await ValidationRecoveryService().inspect(runDirectory: run,
                root: root.appendingPathComponent("work/canary-\(key)"))
            guard status == .verified else { throw Failure.unverified }
            let resultData = try bounded(directory.appendingPathComponent("result.json"))
            guard let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  result["phase"] as? String == "verified" else { throw Failure.unverified }
            tasks.append(["task": key, "recovery": status.rawValue, "result": result,
                "verificationSHA256": hash(verificationData),
                "proposalSHA256": hash(try bounded(directory.appendingPathComponent("proposal/proposal-checkpoint.json")))])
        }
        let trace = try bounded(root.appendingPathComponent("Benchmarks/Dogfood/Results/codex-quota-interruption-20260924.json"))
        guard let failure = try JSONSerialization.jsonObject(with: trace) as? [String: Any],
              failure["failureClass"] as? String == "EXTERNAL_PROVIDER_UNAVAILABLE",
              failure["reason"] as? String == "QUOTA_EXHAUSTION" else { throw Failure.invalidEvidence }
        let packet: [String: Any] = ["schemaVersion": 1, "tasks": tasks,
            "failureTraceSHA256": hash(trace), "failureClass": "EXTERNAL_PROVIDER_UNAVAILABLE",
            "reason": "QUOTA_EXHAUSTION", "quotaObservation": "historical_user_report_not_fresh_dispatch_evidence",
            "dispatchAuthorized": false, "externalInferenceCalls": 0,
            "nextAction": "Revalidate subscription, billing/provider configuration, command compatibility and approved scope before Claude dispatch. Do not repeat successful Canary tasks or promote Stable from this packet."]
        let file = support.appendingPathComponent("bootstrap-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: packet, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        print("Recovery verified for both tasks. Local handoff packet: \(file.path). Dispatch remains blocked.")
    }
    private static func bounded(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 64_000 else { throw Failure.invalidEvidence }
        return try Data(contentsOf: file)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
