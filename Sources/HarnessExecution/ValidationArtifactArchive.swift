import Foundation
import HarnessCore

public struct ValidationArtifactRecord: Codable, Equatable, Sendable {
    public let kind: ProjectValidationArtifact.Kind
    public let files: [File]
    public struct File: Codable, Equatable, Sendable {
        public let relativePath: String
        public let byteCount: Int
        public let sha256: String
    }
}

/// Local evidence snapshot. Receipt hashes bind these bytes, not mutable source paths.
/// This is not an authenticated archive against an attacker who can rewrite both journal and evidence.
public struct ValidationArtifactArchive: Sendable {
    private let directory: URL
    private static let maximumBytes = 64 * 1_048_576
    private static let maximumFileBytes = 16 * 1_048_576

    public init(directory: URL) {
        self.directory = directory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(directory.lastPathComponent)
    }

    public func capture(_ artifacts: [ProjectValidationArtifact]) throws -> [ValidationArtifactRecord] {
        guard artifacts.count <= 16 else { throw RecordedValidationError.invalidReceipt }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var total = 0
        var fileCount = 0
        var records: [ValidationArtifactRecord] = []
        for (index, artifact) in artifacts.enumerated() {
            guard artifact.url.isFileURL else { throw RecordedValidationError.invalidReceipt }
            // Resolve ancestor aliases (e.g. /var), but never follow an artifact's own symlink.
            let root = artifact.url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(artifact.url.lastPathComponent)
            let inputFiles = try files(at: root)
            guard !inputFiles.isEmpty else { throw RecordedValidationError.invalidReceipt }
            var entries: [ValidationArtifactRecord.File] = []
            for input in inputFiles {
                fileCount += 1
                guard fileCount <= 5_000 else { throw RecordedValidationError.invalidReceipt }
                let data = try read(input, total: &total)
                let hash = ValidationSourceIdentity.hash(data)
                if let expected = artifact.expectedSHA256 {
                    guard inputFiles.count == 1, input == root, hash == expected else {
                        throw RecordedValidationError.invalidReceipt
                    }
                }
                let suffix = input == root ? "payload" : String(input.path.dropFirst(root.path.count + 1))
                let relativePath = "\(index)/\(suffix)"
                let target = try safeURL(relativePath)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.synchronize()
                entries.append(.init(relativePath: relativePath, byteCount: data.count, sha256: hash))
            }
            records.append(.init(kind: artifact.kind, files: entries))
        }
        try verify(records)
        return records
    }

    public func verify(_ records: [ValidationArtifactRecord]) throws {
        let entries = records.flatMap(\.files)
        guard records.count <= 16, entries.count <= 5_000,
              records.allSatisfy({ !$0.files.isEmpty }),
              Set(entries.map(\.relativePath)).count == entries.count else {
            throw RecordedValidationError.invalidReceipt
        }
        let expected = try Set(entries.map { try safeURL($0.relativePath).path })
        guard Set(try files(at: directory).map(\.path)) == expected else {
            throw RecordedValidationError.invalidReceipt
        }
        var total = 0
        for entry in entries {
            let data = try read(safeURL(entry.relativePath), total: &total)
            guard data.count == entry.byteCount, ValidationSourceIdentity.hash(data) == entry.sha256 else {
                throw RecordedValidationError.invalidReceipt
            }
        }
    }

    public func satisfies(_ acceptance: XcodeUIAcceptance, records: [ValidationArtifactRecord]) throws -> Bool {
        try verify(records)
        guard records.filter({ $0.kind == .xcodeResult }).count == 1 else {
            throw RecordedValidationError.invalidReceipt
        }
        func json(_ kind: ProjectValidationArtifact.Kind) throws -> Data {
            let matches = records.filter { $0.kind == kind }
            guard matches.count == 1, matches[0].files.count == 1 else { throw RecordedValidationError.invalidReceipt }
            var total = 0
            return try read(safeURL(matches[0].files[0].relativePath), total: &total)
        }
        return try acceptance.isSatisfied(summary: json(.testSummary), tests: json(.testTree))
    }

    private func safeURL(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.contains("\\"), !path.contains("\0") else { throw RecordedValidationError.invalidReceipt }
        return directory.appendingPathComponent(path)
    }

    private func read(_ url: URL, total: inout Int) throws -> Data {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
              let size = values.fileSize, size >= 0, size <= Self.maximumFileBytes else {
            throw RecordedValidationError.invalidReceipt
        }
        total += size
        guard total <= Self.maximumBytes else { throw RecordedValidationError.invalidReceipt }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: size + 1) ?? Data()
        guard data.count == size else { throw RecordedValidationError.invalidReceipt }
        return data
    }

    private func files(at root: URL) throws -> [URL] {
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw RecordedValidationError.invalidReceipt }
        if values.isRegularFile == true { return [root] }
        guard values.isDirectory == true else { throw RecordedValidationError.invalidReceipt }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
            errorHandler: { _, _ in failed = true; return false }) else { throw RecordedValidationError.invalidReceipt }
        var result: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            guard visited <= 7_000 else { throw RecordedValidationError.invalidReceipt }
            let value = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard value.isSymbolicLink != true, value.isRegularFile == true || value.isDirectory == true else {
                throw RecordedValidationError.invalidReceipt
            }
            // Enumeration may return /private/var while URL normalization uses /var.
            // Normalize after rejecting symlinks so inventory and relative paths use one spelling.
            if value.isRegularFile == true { result.append(url.standardizedFileURL.resolvingSymlinksInPath()) }
        }
        guard !failed else { throw RecordedValidationError.invalidReceipt }
        return result.sorted { $0.path < $1.path }
    }
}
