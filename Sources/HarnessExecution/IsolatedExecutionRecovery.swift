import Foundation
import HarnessCore

enum IsolatedExecutionRecovery {
    static func reconcile(evidence: URL, root: URL, stable: URL?) throws {
        let fm = FileManager.default
        for prior in try fm.contentsOfDirectory(at: evidence, includingPropertiesForKeys: nil) where prior.pathExtension == "json" {
            guard var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: prior)) as? [String: Any] else {
                throw IsolatedPackageExecution.Failure.EXECUTION_ISOLATION_UNAVAILABLE
            }
            if let session = saved["supervisorDirectory"] as? String {
                let directory = URL(fileURLWithPath: session).standardizedFileURL
                // Compare paths, not URLs: a directory URL's trailing slash depends on
                // whether it existed when constructed, which differs across restarts.
                guard directory.deletingLastPathComponent().path == evidence.standardizedFileURL.path,
                      directory.path == directory.resolvingSymlinksInPath().path else { throw IsolatedPackageExecution.Failure.invalidScope }
                try ExecutionSupervisor.verifyStopped(directory: directory)
            } else if saved["status"] as? String == "starting" {
                throw IsolatedPackageExecution.Failure.EXECUTION_ISOLATION_UNAVAILABLE
            }
            guard saved["status"] as? String == "starting" else { continue }
            guard saved["worktree"] as? String == root.path,
                  let before = saved["sourceHashesBefore"] as? [String: String],
                  before == (try ExecutionIntegritySnapshot.capture(root, excluding: [".harness-execution", "receipts"])) else {
                throw IsolatedPackageExecution.Failure.EXECUTION_ISOLATION_UNAVAILABLE
            }
            if let stable {
                guard let before = saved["stableHashesBefore"] as? [String: String],
                      before == (try ExecutionIntegritySnapshot.capture(stable, excluding: ["work", ".git", ".build"])) else {
                    throw IsolatedPackageExecution.Failure.EXECUTION_ISOLATION_UNAVAILABLE
                }
            }
            // Preserve the original starting receipt verbatim as evidence.
            try Data(contentsOf: prior).write(to: prior.appendingPathExtension("interrupted-original"), options: .withoutOverwriting)
            saved["status"] = "INTERRUPTED_EXECUTION"
            saved["recovery"] = "guardian stopped; original source and Stable hashes match; reexecution permitted"
            saved["testResult"] = "notVerified"
            try JSONSerialization.data(withJSONObject: saved, options: [.prettyPrinted, .sortedKeys]).write(to: prior, options: .atomic)
        }
    }
}
