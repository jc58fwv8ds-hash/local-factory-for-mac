import Foundation
import HarnessCore

/// Fixed SwiftPM operations only. The outer OS sandbox also confines descendants.
/// This adapter never retries a failed sandbox invocation without containment.
public struct IsolatedPackageExecution: Sendable {
    public enum Failure: Error { case EXECUTION_ISOLATION_UNAVAILABLE, invalidScope, failed }
    public enum Operation: String, Codable, Sendable { case build, test }
    public let candidate: URL
    public let root: URL
    public let taskID: String
    public let protectedPaths: [String]
    public let stable: URL?
    public init(candidate: URL, root: URL, taskID: String, protectedPaths: [String], stable: URL? = nil) {
        self.candidate = candidate; self.root = root; self.taskID = taskID
        self.protectedPaths = protectedPaths
        self.stable = stable
    }
    /// SwiftPM's build system. "native" is deprecated in Swift 6.4 but still the default here; HARNESS_BUILD_SYSTEM=swiftbuild
    /// selects Swift Build (2026-10-11) until it has passed the full suites.
    static var buildSystem: String {
        ProcessInfo.processInfo.environment["HARNESS_BUILD_SYSTEM"] == "swiftbuild" ? "swiftbuild" : "native"
    }

    /// What Swift Build needs beyond the native build (measured 2026-10-11 on a one-test package in this sandbox): it runs
    /// mkdir, touch, derq (entitlements), an ad-hoc codesign, clang-stat-cache, bitcode_strip and the platform's plugin
    /// server, and its linker step makes `TemporaryDirectory.*` directly in /tmp whatever TMPDIR says (writes there are
    /// allowed for that name only; anything else in /tmp stays denied).
    static func swiftBuildAllowances(developer: String, bin: String, quote q: (String) -> String) -> String {
        let system = ["/bin/mkdir", "/usr/bin/touch", "/usr/bin/derq", "/usr/bin/codesign"]
        let toolchain = [bin + "/clang-stat-cache", bin + "/bitcode_strip", developer + "/Platforms/MacOSX.platform/Developer/usr/bin/swift-plugin-server"]
        return "\n(allow process-exec " + (system + toolchain).map { "(literal \(q($0)))" }.joined(separator: " ") + ")"
            + "\n(allow file-read* " + system.map { "(literal \(q($0)))" }.joined(separator: " ") + ")"
            + "\n(allow file-write* (regex #\"^/private/tmp/TemporaryDirectory\\.[A-Za-z0-9]+(/|$)\"))"
    }

    public func execute(_ operation: Operation, evidence: URL) async throws -> BoundedCommandResult {
        let fm = FileManager.default
        let scratch = root.appendingPathComponent(".harness-execution")
        guard candidate == candidate.standardizedFileURL.resolvingSymlinksInPath(),
              root == root.standardizedFileURL.resolvingSymlinksInPath(),
              root.path.hasPrefix(candidate.path + "/work/"),
              scratch == scratch.resolvingSymlinksInPath(),
              protectedPaths.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") && !$0.hasPrefix(".harness-execution") })
        else { throw Failure.invalidScope }
        let lease = try LocalExecutionLease(file: root.appendingPathComponent(".harness-execution-host.lock"))
        defer { withExtendedLifetime(lease) {} }
        let contract = try await RepairAcceptanceContract.capture(root: root, paths: protectedPaths)
        let before = try ExecutionIntegritySnapshot.capture(root, excluding: [".harness-execution", "receipts"])
        let stableBefore = try stable.map { try ExecutionIntegritySnapshot.capture($0, excluding: ["work", ".git", ".build"]) }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
        try IsolatedExecutionRecovery.reconcile(evidence: evidence, root: root, stable: stable)
        // A survivor of an earlier session could still write scratch: stop, never re-execute.
        guard ExecutionProcessIdentity.liveImages(under: scratch)?.isEmpty == true else {
            throw Failure.EXECUTION_ISOLATION_UNAVAILABLE
        }
        let developer = "/Applications/Xcode.app/Contents/Developer"
        let bin = developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin"
        let frameworks = developer + "/Platforms/MacOSX.platform/Developer/Library/Frameworks"
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let tools = ["swift", "swift-package", "swift-build", "swift-test", "swiftc", "swift-driver", "swift-frontend", "swift-autolink-extract", "swift-plugin-server", "clang", "ld", "libtool", "dsymutil"]
        // The time-zone database and ICU data are read-only system data Foundation reads for TimeZone(identifier:) and
        // DateFormatter; without them a generated test that names a zone crashed on a nil time zone, and a correct
        // "yyyy-MM-dd" file name came out wrong, so a right answer failed its tests (2026-10-25).
        let profile = """
        (version 1)
        (deny default)
        (allow process-fork)
        (allow process-info* (target self))
        (allow sysctl-read)
        (allow file-read-metadata)
        (allow file-read* process-exec (literal "/usr/bin/xcrun"))
        (allow process-exec (literal \(q(developer + "/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"))))
        (allow file-read* (subpath "/Applications/Xcode.app/Contents"))
        (allow file-read* (literal "/") (subpath "/usr/lib") (subpath "/System/Library") (subpath "/System/Cryptexes") (subpath \(q(developer))) (subpath \(q(root.path))) (literal "/dev/null"))
        (allow file-read* (subpath "/private/var/db/timezone") (subpath "/usr/share/zoneinfo") (literal "/private/etc/localtime") (subpath "/usr/share/icu"))
        (allow file-write* (subpath \(q(scratch.path))) (literal "/dev/null"))
        (allow process-exec \(tools.map { "(literal \(q(bin + "/" + $0)))" }.joined(separator: " ")) (subpath \(q(scratch.path))))
        """ + (Self.buildSystem == "swiftbuild" ? Self.swiftBuildAllowances(developer: developer, bin: bin, quote: q) : "")
        var record: [String: Any] = ["taskID": taskID, "worktree": root.path,
            "allowedPaths": [scratch.path], "protectedPaths": protectedPaths,
            "allowedOperations": [operation.rawValue], "networkPolicy": "deny",
            "executionPolicyRevision": "swiftpm-contained-v1-experimental", "status": "starting"]
        record["sourceHashesBefore"] = before
        record["stableHashesBefore"] = stableBefore
        let receipt = evidence.appendingPathComponent(operation.rawValue + "-" + UUID().uuidString + ".json")
        let supervisor = evidence.appendingPathComponent("session-" + UUID().uuidString)
        record["supervisorDirectory"] = supervisor.path
        func save() throws {
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]).write(to: receipt, options: .atomic)
        }
        try save()
        do {
            let result = try await ExecutionSupervisor.run(
                helper: candidate.appendingPathComponent(".build/debug/HarnessKernelPilot"), directory: supervisor,
                arguments: ["-p", profile, bin + "/swift", operation.rawValue,
                    "--package-path", root.path, "--scratch-path", scratch.appendingPathComponent("build").path,
                    "--cache-path", scratch.appendingPathComponent("cache").path,
                    "--config-path", scratch.appendingPathComponent("config").path,
                    "--security-path", scratch.appendingPathComponent("security").path,
                    "-Xswiftc", "-F", "-Xswiftc", frameworks,
                    // One "file:line:col: error:" line per diagnostic, as every parser here expects: Swift 6.4's grouped
                    // style prints the location only for the first diagnostic of a group (2026-10-10: the examiner's
                    // pruning found no error line and 12 of 112 runs gave no verdict).
                    "-Xswiftc", "-diagnostic-style", "-Xswiftc", "llvm",
                    "-Xlinker", "-rpath", "-Xlinker", frameworks,
                    "--build-system", Self.buildSystem, "--disable-sandbox"]
                    + (Self.buildSystem == "swiftbuild"
                       ? ["-Xlinker", "-rpath", "-Xlinker", developer + "/Platforms/MacOSX.platform/Developer/usr/lib"] : []),
                workspace: root,
                environment: ["PATH": bin + ":/usr/bin:/bin", "HOME": scratch.path,
                    "TMPDIR": scratch.path, "DEVELOPER_DIR": developer,
                    "SDKROOT": developer + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
                    "LIBTOOL": bin + "/libtool", "CC": bin + "/clang",
                    "CLANG_MODULE_CACHE_PATH": scratch.appendingPathComponent("modules").path]).withoutColorCodes()
            // --disable-sandbox disables only SwiftPM's nested sandbox, never our outer one.
            let current = try await RepairAcceptanceContract.capture(root: root, paths: protectedPaths)
            let changed = ExecutionIntegritySnapshot.changes(before, try ExecutionIntegritySnapshot.capture(root, excluding: [".harness-execution", "receipts"]))
            record["filesChanged"] = changed
            if let stable, let stableBefore {
                record["stableIntegrity"] = stableBefore == (try ExecutionIntegritySnapshot.capture(stable, excluding: ["work", ".git", ".build"]))
            } else { record["stableIntegrity"] = "notMeasured" }
            record["protectedIntegrity"] = current.protectedFiles == contract.protectedFiles
            record["exitStatus"] = result.exitCode; record["output"] = result.output
            record["status"] = result.exitCode == 0 ? "commandPassed" : "commandFailed"
            record["testResult"] = operation == .test && result.exitCode == 0 ? "commandPassedNotAdjudicated" : "notVerified"
            record["integrityViolation"] = !changed.isEmpty || current.protectedFiles != contract.protectedFiles || (record["stableIntegrity"] as? Bool) == false
            record["policyViolation"] = "OS denial telemetry unavailable; integrity checked separately"
            try save()
            guard result.exitCode == 0, changed.isEmpty, current.protectedFiles == contract.protectedFiles,
                  (record["stableIntegrity"] as? Bool) != false else { throw Failure.failed }
            return result
        } catch {
            record["error"] = String(describing: error)
            if record["exitStatus"] == nil { record["status"] = "executionFailed" }
            if operation == .test {
                let verdict = VerificationAdjudication.classify(output: record["output"] as? String ?? "",
                    timedOut: (error as? BoundedCommandError) == .timedOut)
                let adjudicated = receipt.deletingPathExtension().appendingPathExtension("adjudicated.json")
                try JSONEncoder().encode(verdict).write(to: adjudicated, options: .atomic)
            }
            if let after = try? ExecutionIntegritySnapshot.capture(root, excluding: [".harness-execution", "receipts"]) {
                record["filesChanged"] = ExecutionIntegritySnapshot.changes(before, after)
            }
            if let current = try? await RepairAcceptanceContract.capture(root: root, paths: protectedPaths) {
                record["protectedIntegrity"] = current.protectedFiles == contract.protectedFiles
            }
            if let stable, let stableBefore, let after = try? ExecutionIntegritySnapshot.capture(stable, excluding: ["work", ".git", ".build"]) {
                record["stableIntegrity"] = stableBefore == after
            }
            try save(); throw error
        }
    }
}
