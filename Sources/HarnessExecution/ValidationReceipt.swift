import Foundation
import HarnessCore

public struct ValidationReceipt: Codable, Sendable {
    public let schemaVersion: Int
    public let runID: UUID
    public let rootPath: String
    public let sourceDigest: String
    public let revision: Int
    public let report: ProjectValidationReport
    public var artifacts: [ValidationArtifactRecord]? = nil
    public var uiAcceptance: XcodeUIAcceptance? = nil
}

struct ValidationReceiptStore: Sendable {
    let runDirectory: URL

    func save(_ receipt: ValidationReceipt) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        guard data.count <= 1_048_576 else { throw RecordedValidationError.invalidReceipt }
        let url = runDirectory.appendingPathComponent("validation.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        return ValidationSourceIdentity.hash(data)
    }

    func verified(hash: String, runID: UUID, root: URL, sourceDigest: String?, revision: Int) throws -> ValidationReceipt {
        let url = runDirectory.appendingPathComponent("validation.json")
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let size = values.fileSize, size <= 1_048_576 else { throw RecordedValidationError.invalidReceipt }
        let data = try Data(contentsOf: url)
        guard ValidationSourceIdentity.hash(data) == hash else { throw RecordedValidationError.invalidReceipt }
        let receipt = try JSONDecoder().decode(ValidationReceipt.self, from: data)
        guard [1, 2].contains(receipt.schemaVersion), receipt.runID == runID, receipt.rootPath == root.path,
              sourceDigest == nil || receipt.sourceDigest == sourceDigest, receipt.revision == revision else {
            throw RecordedValidationError.invalidReceipt
        }
        if receipt.schemaVersion == 1 {
            guard receipt.artifacts == nil, receipt.uiAcceptance == nil else { throw RecordedValidationError.invalidReceipt }
        } else {
            guard let records = receipt.artifacts else { throw RecordedValidationError.invalidReceipt }
            let archive = ValidationArtifactArchive(directory: runDirectory.appendingPathComponent("evidence"))
            try archive.verify(records)
            if let acceptance = receipt.uiAcceptance, receipt.report.succeeded {
                guard try archive.satisfies(acceptance, records: records) else { throw RecordedValidationError.invalidReceipt }
            }
        }
        return receipt
    }
}
