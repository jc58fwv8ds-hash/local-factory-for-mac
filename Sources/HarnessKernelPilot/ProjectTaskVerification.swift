import Foundation
import HarnessCore
import HarnessExecution

enum ProjectTaskVerification {
    static func check(arguments: [String]) async throws {
        guard arguments.count == 4 else { throw VerificationError.missingRun }
        let root = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
        guard !FileManager.default.fileExists(atPath: output.path), output != root,
              !output.path.hasPrefix(root.path + "/") else { throw VerificationError.missingRun }
        let files = try await ProjectFileEditor().editableFiles(rootPath: root.path)
        let paths = files.map(\.relativePath).filter { $0 == "Package.swift" || $0.contains("Tests/") }
        guard paths.contains("Package.swift"), paths.contains(where: { $0.contains("Tests/") }) else {
            throw VerificationError.missingRun
        }
        let contract = try await RepairAcceptanceContract.capture(root: root, paths: paths)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(contract).write(to: output.appendingPathComponent("acceptance-contract.json"), options: .atomic)
        try await run(root: root, output: output, contract: contract)
    }

    static func run(root: URL, output: URL, contract: RepairAcceptanceContract) async throws {
        do {
            let current = try await RepairAcceptanceContract.capture(root: root, paths: contract.protectedFiles.keys.sorted())
            guard current.protectedFiles == contract.protectedFiles else { throw RepairAcceptanceError.protectedFilesChanged }
            // Explicit package mode: no Xcode/device installation and no automatic retry.
            let validator = RecordedProjectValidationService(provider: SwiftPackageValidationService(),
                directory: output.appendingPathComponent("validation"), requireTests: true)
            let report = try await validator.validate(rootPath: root.path)
            guard let run = await validator.lastRunDirectory else { throw VerificationError.missingRun }
            if !report.succeeded {
                try save(Decision(status: "needs-repair", message: "変更は保存しましたが、ビルドまたはテストが通りませんでした。自動再試行せず停止します。",
                    validationRun: run.path, evidence: nil), output: output)
                throw VerificationError.failed
            }
            let evidence = try await RepairAcceptanceEvaluator().evaluate(contract: contract, root: root, validationRun: run)
            let decision = Decision(status: "verified-package", message: "固定したテストとビルドに合格しました。実機の操作やアプリ全体の完成は別途確認します。",
                validationRun: run.path, evidence: evidence)
            try save(decision, output: output)
            print(decision.message)
        } catch {
            // Preserve a more specific decision already saved above.
            if !FileManager.default.fileExists(atPath: output.appendingPathComponent("verification.json").path) {
                try save(Decision(status: "unverified", message: "検証を完了できませんでした。変更や合格を推定せず停止します。",
                    validationRun: nil, evidence: nil), output: output)
            }
            throw error
        }
    }

    private static func save(_ decision: Decision, output: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(decision).write(to: output.appendingPathComponent("verification.json"), options: .atomic)
    }
    private struct Decision: Encodable {
        let status: String
        let message: String
        let validationRun: String?
        let evidence: String?
    }
    private enum VerificationError: Error { case failed, missingRun }
}
