import CryptoKit
import Darwin
import Foundation

/// One DerivedData folder per project, kept between checks (2026-11-25, the user: Xcode's developer data had grown to 55 GB,
/// and 「とにかく効率化してスピードを上げる」). Every check used to build into a new temporary folder and delete it, so each
/// one compiled the whole app from nothing, twice (the build, then the test build). Kept here, later checks compile only
/// what changed. The folders live in macOS's per-user cache folder, which the build sandbox already lets builds write
/// (XcodeIsolation), and their total is held under `limitBytes` by removing the least recently used.
public enum BuildCache {
    public static let limitBytes: Int64 = 12 * 1_073_741_824

    private static let lock = NSLock()
    nonisolated(unsafe) private static var inUse: Set<String> = []

    /// The cache folder root: `<user cache>/LocalFactory/DerivedData`, nil when macOS gives none.
    public static var root: URL? {
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, length)
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("LocalFactory/DerivedData", isDirectory: true)
    }

    /// The project's folder, reserved for this check; nil when another check of the same project holds it (that check
    /// then builds in a temporary folder as before). `stamp` names the Xcode in use: a different one starts the folder anew.
    public static func checkOut(project: URL, stamp: String, root: URL? = BuildCache.root) -> URL? {
        guard let root else { return nil }
        let path = project.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let name = project.lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40) + "-" + digest
        let folder = root.appendingPathComponent(String(name), isDirectory: true)
        lock.lock(); defer { lock.unlock() }
        guard !inUse.contains(folder.path) else { return nil }
        let manager = FileManager.default
        let stampFile = folder.appendingPathComponent(".xcode-stamp")
        if let saved = try? String(contentsOf: stampFile, encoding: .utf8), saved != stamp {
            try? manager.removeItem(at: folder)
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        } catch { return nil }
        inUse.insert(folder.path)
        return folder
    }

    /// Done with the folder: it counts as just used, and the cache is trimmed to its limit.
    public static func checkIn(_ folder: URL, root: URL? = BuildCache.root, limit: Int64 = BuildCache.limitBytes) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        lock.lock(); inUse.remove(folder.path); let busy = inUse; lock.unlock()
        if let root { trim(root, limit: limit, keeping: busy) }
    }

    /// The folder after a build that failed because of the cache itself (an Xcode update, a cut-off earlier build):
    /// emptied so the next try starts clean. Returns whether the output showed such a failure.
    @discardableResult
    public static func clearIfStale(_ folder: URL, output: String) -> Bool {
        let marks = ["was compiled with module cache path", "module file", "is out of date and needs to be rebuilt",
                     "database is locked", "unable to attach DB", "PCH file", "malformed or corrupted"]
        guard marks.contains(where: { output.contains($0) }) else { return false }
        let manager = FileManager.default
        for item in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent != ".xcode-stamp" {
            try? manager.removeItem(at: item)
        }
        return true
    }

    /// Removes the least recently used project folders until the total is under `limit`; folders in use stay.
    static func trim(_ root: URL, limit: Int64, keeping busy: Set<String>) {
        let manager = FileManager.default
        let folders = ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .map { url -> (url: URL, date: Date, size: Int64) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, date, DeveloperDataJanitor.size(of: url))
            }
            .sorted { $0.date < $1.date }
        var total = folders.reduce(0) { $0 + $1.size }
        for folder in folders where total > limit && !busy.contains(folder.url.path) {
            try? manager.removeItem(at: folder.url)
            total -= folder.size
        }
    }
}
