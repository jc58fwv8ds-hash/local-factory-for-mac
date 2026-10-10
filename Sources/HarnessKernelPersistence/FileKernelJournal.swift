import Darwin
import Foundation
import HarnessKernelContracts

/// One atomically published file per event avoids torn JSONL tails.
/// Use an app-owned local directory, not an untrusted project checkout.
public struct FileKernelJournal: KernelJournal {
    public static let maximumEventBytes = 1_048_576
    public static let maximumEvents = 10_000
    public static let maximumJournalBytes = 64 * 1_048_576
    private let directory: URL

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw KernelError.corruptJournal }
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let attributes = try self.directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
            throw KernelError.corruptJournal
        }
    }

    public func read() throws -> [KernelEvent] {
        try withLock {
            let files = try eventFiles()
            var runID: UUID?
            return try files.enumerated().map { index, file in
                let event = try decode(file)
                guard event.sequence == index + 1, runID == nil || runID == event.runID else {
                    throw KernelError.corruptJournal
                }
                runID = event.runID
                return event
            }
        }
    }

    public func append(_ event: KernelEvent) throws {
        try withLock {
            guard event.schemaVersion == 1 else { throw KernelError.unsupportedSchema }
            let files = try eventFiles()
            guard event.sequence == files.count + 1 else { throw KernelError.journalConflict }
            guard files.count < Self.maximumEvents else { throw KernelError.journalLimitExceeded }
            if let last = files.last {
                let previous = try decode(last)
                guard previous.runID == event.runID, previous.sequence == files.count else {
                    throw KernelError.journalConflict
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(event)
            guard data.count <= Self.maximumEventBytes else { throw KernelError.journalLimitExceeded }
            let currentBytes = try files.reduce(0) { total, file in
                total + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard currentBytes + data.count <= Self.maximumJournalBytes else {
                throw KernelError.journalLimitExceeded
            }
            let url = directory.appendingPathComponent(Self.filename(event.sequence))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
            let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw Self.posixError() }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw Self.posixError() }
        }
    }

    private func eventFiles() throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= Self.maximumEvents else { throw KernelError.journalLimitExceeded }
        var totalBytes = 0
        for (index, file) in files.enumerated() {
            guard file.lastPathComponent == Self.filename(index + 1) else {
                throw KernelError.corruptJournal
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= Self.maximumEventBytes else {
                throw KernelError.corruptJournal
            }
            totalBytes += size
            guard totalBytes <= Self.maximumJournalBytes else { throw KernelError.journalLimitExceeded }
        }
        return files
    }

    private func decode(_ file: URL) throws -> KernelEvent {
        let event: KernelEvent
        do { event = try JSONDecoder().decode(KernelEvent.self, from: Data(contentsOf: file)) }
        catch { throw KernelError.corruptJournal }
        guard event.schemaVersion == 1 else { throw KernelError.unsupportedSchema }
        return event
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let lockURL = directory.appendingPathComponent(".journal.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw KernelError.journalConflict }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func filename(_ sequence: Int) -> String { String(format: "%08d.json", sequence) }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
