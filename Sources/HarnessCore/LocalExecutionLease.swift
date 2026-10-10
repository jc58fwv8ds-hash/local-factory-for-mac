import Darwin
import Foundation

/// Nonblocking, cooperating-process exclusion in an app-owned local directory.
/// Keep the token alive across the entire operation. Never delete or replace its lock file.
public final class LocalExecutionLease: @unchecked Sendable {
    private let descriptor: Int32

    public init(file: URL) throws {
        guard file.isFileURL else { throw LocalExecutionLeaseError.unavailable }
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LocalExecutionLeaseError.unavailable }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw LocalExecutionLeaseError.unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw LocalExecutionLeaseError.inUse }
            throw LocalExecutionLeaseError.unavailable
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum LocalExecutionLeaseError: Error, Equatable, Sendable { case inUse, unavailable }
