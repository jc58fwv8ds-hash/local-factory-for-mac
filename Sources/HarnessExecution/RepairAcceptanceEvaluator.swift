import Foundation
import HarnessCore
import HarnessKernelContracts

/// Captured by the host before editing; the builder cannot submit a replacement contract.
public struct RepairAcceptanceContract: Encodable, Sendable {
    public let protectedFiles: [String: String]

    public static func capture(root: URL, paths: [String]) async throws -> Self {
        guard !paths.isEmpty, paths.count <= 100, Set(paths).count == paths.count else {
            throw KernelError.invalidPlan
        }
        let editor = ProjectFileEditor()
        var hashes: [String: String] = [:]
        for path in paths {
            let document = try await editor.load(rootPath: root.path, relativePath: path)
            hashes[path] = ValidationSourceIdentity.hash(Data(document.content.utf8))
        }
        return Self(protectedFiles: hashes)
    }
}

/// A deterministic acceptance gate, separate from generation. Not an LLM or visual evaluator.
public struct RepairAcceptanceEvaluator: Sendable {
    public init() {}

    public func evaluate(contract: RepairAcceptanceContract, root: URL, validationRun: URL) async throws -> String {
        try await checkProtectedFiles(contract: contract, root: root)
        let reference = try await VerifiedValidationReference.read(runDirectory: validationRun, root: root)
        try await checkProtectedFiles(contract: contract, root: root)
        return reference
    }

    private func checkProtectedFiles(contract: RepairAcceptanceContract, root: URL) async throws {
        let current = try await RepairAcceptanceContract.capture(root: root, paths: contract.protectedFiles.keys.sorted())
        guard current.protectedFiles == contract.protectedFiles else { throw RepairAcceptanceError.protectedFilesChanged }
    }
}

public enum RepairAcceptanceError: Error, Equatable, Sendable {
    case protectedFilesChanged
}
