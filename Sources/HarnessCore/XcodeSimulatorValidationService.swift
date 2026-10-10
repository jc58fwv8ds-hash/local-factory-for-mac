import Foundation

/// Opt-in simulator validation. The caller must trust the project, including its build scripts.
/// Fixed argument arrays are not a substitute for an OS sandbox or project approval.
public struct XcodeSimulatorValidationService: ProjectValidating {
    private let project: String
    private let scheme: String
    private let deviceID: UUID
    private let artifacts: URL

    public init(project: String, scheme: String, deviceID: UUID, artifacts: URL) {
        self.project = project
        self.scheme = scheme
        self.deviceID = deviceID
        self.artifacts = artifacts.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func support(rootPath: String) async -> ProjectValidationSupport? {
        guard validProjectName,
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: rootPath)
                .appendingPathComponent(project).path) else { return nil }
        return ProjectValidationSupport(system: .xcode, containerName: project)
    }

    public func validate(rootPath: String) async throws -> ProjectValidationReport {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard await support(rootPath: root.path) != nil,
              artifacts.path != root.path, !artifacts.path.hasPrefix(root.path + "/"),
              !FileManager.default.fileExists(atPath: artifacts.path) else {
            throw XcodeSimulatorValidationError.invalidConfiguration
        }
        let devices = try await LocalSimulatorService().listDevices()
        guard devices.contains(where: {
            UUID(uuidString: $0.id) == deviceID && $0.runtimeIdentifier.contains("iOS")
        }) else { throw XcodeSimulatorValidationError.unavailableDevice }
        let environment = try await XcodeCommandEnvironmentResolver().environment(
            for: "xcodebuild", currentDirectoryURL: root
        )
        // A fresh, retained output directory prevents overwriting earlier evidence.
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let started = Date()
        let base = ["xcodebuild", "-project", project, "-scheme", scheme,
                    "-configuration", "Debug", "-sdk", "iphonesimulator",
                    "-destination", "platform=iOS Simulator,id=\(deviceID.uuidString)",
                    "-derivedDataPath", artifacts.appendingPathComponent("DerivedData").path,
                    "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
        var checks = [try await run(base + ["build-for-testing"], kind: .xcodeBuild,
                                   root: root, environment: environment)]
        var evidence: [ProjectValidationArtifact]?
        if checks[0].succeeded {
            checks.append(try await run(base + [
                "test-without-building", "-parallel-testing-enabled", "NO",
                "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "60",
                "-resultBundlePath", artifacts.appendingPathComponent("Tests.xcresult").path
            ], kind: .xcodeTest, root: root, environment: environment))
            let bundle = artifacts.appendingPathComponent("Tests.xcresult")
            if FileManager.default.fileExists(atPath: bundle.path) {
                let exported = try await XcodeResultExportService().export(
                    bundle: bundle, to: artifacts.appendingPathComponent("exported")
                )
                evidence = exported.artifacts
                if !exported.summary.passed(on: deviceID) {
                    checks.append(ProjectValidationCheck(kind: .xcodeTest, succeeded: false, exitCode: 1,
                        output: "[Local Factory] Xcodeの実行件数・失敗数・対象Simulatorを確認できませんでした。",
                        outputWasTruncated: false, duration: 0))
                }
            } else if checks.last?.succeeded == true {
                throw XcodeEvidenceError.invalidResult
            }
        }
        return ProjectValidationReport(startedAt: started, finishedAt: .now, checks: checks, artifacts: evidence)
    }

    private var validProjectName: Bool {
        !project.contains("/") && !project.contains("\\")
            && project.hasSuffix(".xcodeproj") && !project.hasPrefix("-")
            && !scheme.isEmpty && !scheme.hasPrefix("-")
    }

    private func run(_ arguments: [String], kind: ProjectValidationKind, root: URL,
                     environment: [String: String]) async throws -> ProjectValidationCheck {
        let result = try await BoundedCommandRunner(timeout: .seconds(180), maximumOutputBytes: 120_000).run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments,
            currentDirectoryURL: root, environment: environment
        )
        return ProjectValidationCheck(kind: kind, succeeded: result.exitCode == 0,
                                      exitCode: result.exitCode, output: result.output,
                                      outputWasTruncated: result.outputWasTruncated, duration: result.duration)
    }
}

public enum XcodeSimulatorValidationError: Error {
    case invalidConfiguration, unavailableDevice
}
