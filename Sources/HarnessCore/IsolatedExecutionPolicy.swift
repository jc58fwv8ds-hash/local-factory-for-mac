import Foundation
import CryptoKit

/// Host-authored execution contract, never a model's assertion of safety.
public struct IsolatedExecutionPolicy: Sendable {
    public let candidate: URL
    public let workspace: URL
    public let scratch: URL
    public let executable: URL
    public let executableHash: String
    public let protectedPaths: [URL]
    public init(candidate: URL, workspace: URL, scratch: URL, executable: URL,
                executableHash: String, protectedPaths: [URL]) {
        self.candidate = candidate; self.workspace = workspace; self.scratch = scratch
        self.executable = executable; self.executableHash = executableHash
        self.protectedPaths = protectedPaths
    }
    public enum Failure: Error { case scope, staleExecutable }
    public func profile() throws -> String {
        let urls = [candidate, workspace, scratch, executable] + protectedPaths
        guard urls.allSatisfy({ $0.isFileURL && $0.standardizedFileURL == $0.resolvingSymlinksInPath().standardizedFileURL }),
              inside(workspace, candidate), inside(scratch, workspace), inside(executable, workspace),
              !inside(executable, scratch),
              protectedPaths.allSatisfy({ !inside($0, scratch) && !inside(scratch, $0) && $0 != scratch }),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.scope }
        let actual = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        guard actual == executableHash else { throw Failure.staleExecutable }
        func quote(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // No network, Mach service lookup, credential access, process-fork, install/sign,
        // or arbitrary process execution is granted. OS compatibility is tested separately.
        return """
        (version 1)
        (deny default)
        (allow sysctl-read (sysctl-name-regex "^hw[.]") (sysctl-name-regex "^kern[.]os") (sysctl-name-regex "^security[.]mac[.]img4[.]"))
        (allow process-info* (target self))
        (allow process-exec (literal \(quote(executable.path))))
        (allow file-read-metadata)
        (allow file-read* (literal "/") (subpath "/usr/lib") (subpath "/System/Library") (subpath "/System/Cryptexes") (literal "/dev/null") (literal \(quote(executable.path))))
        (allow file-read* file-write* (subpath \(quote(scratch.path))))
        """
    }
    private func inside(_ child: URL, _ parent: URL) -> Bool {
        child.path.hasPrefix(parent.path + "/")
    }
}
