import Darwin
import Foundation

/// The OS sandbox for building and testing an Xcode project (2026-10-12 review: SwiftPM packages ran isolated, Xcode
/// projects did not). xcodebuild talks to many system services (the build service, the Simulator, the test runner), so
/// unlike the SwiftPM profile reads and service lookups stay open; what the AI-written code and its build scripts lose is
/// the network (only local sockets remain) and every write outside the run's own folder and macOS's per-user temporary and
/// cache folders. Measured on HarnessRemote (iOS app, 8 tests): build 4.3 s and tests pass inside it, a write to
/// ~/Desktop and a request to example.com are refused. Packages are fetched before, outside it (see the service).
public enum XcodeIsolation {
    /// Swift macro plugins put themselves in a sandbox, which a sandboxed process may not do; the outer one stays.
    public static let buildSettings = ["OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox"]

    public static func profile(workDirectory: URL) -> String {
        func quote(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let writable = [workDirectory.path] + [_CS_DARWIN_USER_TEMP_DIR, _CS_DARWIN_USER_CACHE_DIR].compactMap(userDirectory)
        return """
        (version 1)
        (allow default)
        (deny network*)
        (allow network* (local unix-socket))
        (deny file-write*)
        (allow file-write* \(writable.map { "(subpath \(quote(resolved($0))))" }.joined(separator: " "))
            (literal "/dev/null") (literal "/dev/ptmx") (literal "/dev/tty") (regex #"^/dev/ttys[0-9]+$"))
        """
    }

    private static func userDirectory(_ name: Int32) -> String? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        confstr(name, &buffer, length)
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// The sandbox matches real paths: /tmp and /var are links to /private/....
    /// Foundation's `resolvingSymlinksInPath` drops "/private" and leaves paths that do not exist yet alone, so the real
    /// path of the longest existing parent is taken with realpath(3) and the rest appended.
    static func resolved(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let real = realpath(existing.path, nil) else { return path }
        defer { free(real) }
        return rest.reduce(URL(fileURLWithPath: String(cString: real))) { $0.appendingPathComponent($1) }.path
    }
}
