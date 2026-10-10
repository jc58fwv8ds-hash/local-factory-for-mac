import CryptoKit
import Foundation

public struct XcodeResultExport: Sendable {
    public let summary: XcodeTestSummary
    public let artifacts: [ProjectValidationArtifact]
}

/// Reads an existing result bundle; never builds or starts a simulator.
public struct XcodeResultExportService: Sendable {
    public init() {}

    public func export(bundle: URL, to directory: URL) async throws -> XcodeResultExport {
        let environment = try await XcodeCommandEnvironmentResolver().environment(for: "xcodebuild")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var artifacts = [ProjectValidationArtifact(kind: .xcodeResult, url: bundle)]
        var summary: XcodeTestSummary?
        for (command, kind) in [("summary", ProjectValidationArtifact.Kind.testSummary), ("tests", .testTree)] {
            let result = try await run(["xcresulttool", "get", "test-results", command,
                                       "--schema-version", "0.1.0", "--path", bundle.path, "--compact"], environment)
            let data = Data(result.output.utf8)
            if command == "summary" { summary = try JSONDecoder().decode(XcodeTestSummary.self, from: data) }
            let url = directory.appendingPathComponent(command + ".json")
            try data.write(to: url, options: .atomic)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            artifacts.append(ProjectValidationArtifact(kind: kind, url: url, expectedSHA256: hash))
        }
        let attachments = directory.appendingPathComponent("attachments")
        _ = try await run(["xcresulttool", "export", "attachments", "--schema-version", "0.1.0",
                           "--path", bundle.path, "--output-path", attachments.path], environment)
        artifacts.append(ProjectValidationArtifact(kind: .testAttachments, url: attachments))
        guard let summary else { throw XcodeEvidenceError.invalidResult }
        return XcodeResultExport(summary: summary, artifacts: artifacts)
    }

    private func run(_ args: [String], _ environment: [String: String]) async throws -> BoundedCommandResult {
        let result = try await BoundedCommandRunner(timeout: .seconds(30), maximumOutputBytes: 1_048_576).run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: args, environment: environment
        )
        guard result.exitCode == 0, !result.outputWasTruncated else { throw XcodeEvidenceError.exportFailed }
        return result
    }
}
