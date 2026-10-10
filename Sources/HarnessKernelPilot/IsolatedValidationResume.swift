import Foundation
import HarnessCore
import HarnessExecution

/// Resume verification only; never regenerate a proposal or silently reapply an edit.
enum IsolatedValidationResume {
    private struct SavedContract: Decodable { let protectedFiles: [String: String] }
    enum Failure: Error { case scope, unresolvedEdits }
    static func run(_ arguments: [String]) async throws {
        guard arguments.count == 4 else { throw Failure.scope }
        let candidate = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let key = arguments[3]
        guard candidate.lastPathComponent == "dogfood-candidate",
              key.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { throw Failure.scope }
        let root = candidate.appendingPathComponent("work/canary-" + key)
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/Dogfood/" + key)
        let lease = try LocalExecutionLease(file: output.appendingPathComponent("runner.lock"))
        defer { withExtendedLifetime(lease) {} }
        let state = try await RecoverableFileBatch(directory: output.appendingPathComponent("transaction")).inspect(root: root)
        guard state.files.allSatisfy({ $0.status == "applied" }) else { throw Failure.unresolvedEdits }
        let contract = try JSONDecoder().decode(SavedContract.self,
            from: Data(contentsOf: output.appendingPathComponent("acceptance-contract.json")))
        let paths = Array(contract.protectedFiles.keys)
        let current = try await RepairAcceptanceContract.capture(root: root, paths: paths)
        guard current.protectedFiles == contract.protectedFiles else { throw RepairAcceptanceError.protectedFilesChanged }
        let executor = IsolatedPackageExecution(candidate: candidate, root: root, taskID: key,
            protectedPaths: paths, stable: candidate.deletingLastPathComponent().deletingLastPathComponent())
        _ = try await GeneratedCodeExecutionGate.executePackage(executor, operation: .build, evidence: output.appendingPathComponent("isolation"))
        _ = try await GeneratedCodeExecutionGate.executePackage(executor, operation: .test, evidence: output.appendingPathComponent("isolation"))
        print("Isolated validation resumed; no proposal regenerated. Specification adjudication remains separate.")
    }
}
