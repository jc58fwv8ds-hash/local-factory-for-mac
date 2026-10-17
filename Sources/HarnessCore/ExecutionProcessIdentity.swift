import Darwin
import Foundation

/// PID reuse cannot authorize signaling a different process.
public struct ExecutionProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public static func current() throws -> Self {
        guard let value = read(getpid()) else { throw BoundedCommandError.unavailable }
        return value
    }
    public static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != 5 else { return nil } // SZOMB is not a running writer.
        return .init(pid: pid, uid: info.pbi_uid, startedSeconds: info.pbi_start_tvsec,
                     startedMicroseconds: info.pbi_start_tvusec)
    }
    public var isAlive: Bool { Self.read(pid) == self }

    /// Live processes of this user whose executable image lies under `directory`.
    /// Build/test products run from the scratch directory and forks keep their image,
    /// so this finds survivors that escaped both parent links and process groups.
    /// Returns nil when the process table cannot be read completely.
    public static func liveImages(under directory: URL) -> [Int32]? {
        let prefix = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < pids.count else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 1, pid != getpid(), let identity = read(pid), identity.uid == getuid(),
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix(prefix)
        }
    }
}
