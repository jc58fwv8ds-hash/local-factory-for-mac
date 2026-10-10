import Foundation

public struct SwiftPackageValidationService: ProjectValidating, Sendable {
    private let disableSwiftPMSandbox: Bool
    private let runner = ValidationCommandRunner()
    private let environmentResolver = XcodeCommandEnvironmentResolver()

    public init(disableSwiftPMSandbox: Bool = false) {
        self.disableSwiftPMSandbox = disableSwiftPMSandbox
    }

    public func support(rootPath: String) async -> ProjectValidationSupport? {
        guard FileManager.default.fileExists(
            atPath: resolvedRootURL(rootPath).appendingPathComponent("Package.swift").path
        ) else { return nil }
        return ProjectValidationSupport(system: .swiftPackage)
    }

    public func validate(rootPath: String) async throws -> ProjectValidationReport {
        let rootURL = resolvedRootURL(rootPath)
        guard FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("Package.swift").path
        ) else {
            throw ProjectValidationError.unsupportedProject
        }

        let startedAt = Date()
        var checks: [ProjectValidationCheck] = []
        let build = try await run(kind: .build, rootURL: rootURL)
        checks.append(build)
        if build.succeeded {
            checks.append(try await run(kind: .test, rootURL: rootURL))
        }
        return ProjectValidationReport(
            startedAt: startedAt,
            finishedAt: .now,
            checks: checks
        )
    }

    private func resolvedRootURL(_ rootPath: String) -> URL {
        URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private func run(
        kind: ProjectValidationKind,
        rootURL: URL
    ) async throws -> ProjectValidationCheck {
        var arguments = ["swift", kind == .build ? "build" : "test"]
        if disableSwiftPMSandbox {
            arguments.append("--disable-sandbox")
        }
        arguments.append(contentsOf: ["--package-path", rootURL.path])
        let environment: [String: String]
        do {
            environment = try await environmentResolver.environment(
                for: "swift",
                currentDirectoryURL: rootURL
            )
        } catch {
            throw ProjectValidationError.commandUnavailable
        }
        let result = try await runner.run(
            kind: kind,
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments,
            currentDirectoryURL: rootURL,
            environment: environment
        )
        let commandOutput = result.output
        let didExecuteTests = kind != .test
            || result.exitCode != 0
            || Self.outputShowsExecutedTests(commandOutput)
        let output = didExecuteTests
            ? commandOutput
            : Self.missingTestExecutionMessage(after: commandOutput)
        return ProjectValidationCheck(
            kind: kind,
            succeeded: result.exitCode == 0 && didExecuteTests,
            exitCode: result.exitCode,
            output: output,
            outputWasTruncated: result.outputWasTruncated,
            duration: result.duration
        )
    }

    private static func outputShowsExecutedTests(_ output: String) -> Bool {
        let markers = [
            "Test Suite '",
            "Test run started",
            "Test run with ",
            "Test run passed",
            "Test run failed"
        ]
        return markers.contains { output.localizedCaseInsensitiveContains($0) }
    }

    private static func missingTestExecutionMessage(after output: String) -> String {
        let message = "[Local Factory] swift testは終了コード0でしたが、テストの実行を確認できませんでした。テスト検出とXcode／Command Line Toolsを確認してください。"
        return output.isEmpty ? message : "\(output)\n\n\(message)"
    }
}
