import Foundation
import HarnessKernelContracts

/// App-owned lookup only. The referenced journal/receipt must still pass Recovery verification.
struct RootRunIndex {
    let directory: URL

    func save(runID: UUID, root: URL) throws {
        let url = location(root)
        try Data(runID.uuidString.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    func load(root: URL) throws -> UUID? {
        let url = location(root)
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 36,
              let value = String(data: try Data(contentsOf: url), encoding: .utf8),
              let id = UUID(uuidString: value), value == id.uuidString else {
            throw KernelError.corruptJournal
        }
        return id
    }

    private func location(_ root: URL) -> URL {
        let key = ValidationSourceIdentity.hash(Data(root.path.utf8))
        return directory.appendingPathComponent("latest-\(key).run")
    }
}

public protocol ProjectValidationRecovering: Sendable {
    func recoverValidation(rootPath: String) async throws -> ValidationRecoveryStatus?
}
