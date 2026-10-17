import Foundation

public struct XcodeProjectValidationService: ProjectValidating, Sendable {
    private let locator = XcodeProjectLocator()
    private let environmentResolver = XcodeCommandEnvironmentResolver()
    private let runner = ValidationCommandRunner()
    private let simulatorService = LocalSimulatorService()

    public init() {}

    public func support(rootPath: String) async -> ProjectValidationSupport? {
        guard let container = locator.locate(rootPath: rootPath) else { return nil }
        return ProjectValidationSupport(
            system: .xcode,
            containerName: container.name
        )
    }

    public func validate(rootPath: String) async throws -> ProjectValidationReport {
        guard let container = locator.locate(rootPath: rootPath) else {
            throw ProjectValidationError.unsupportedProject
        }
        let rootURL = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let environment = try await xcodeEnvironment(rootURL: rootURL)

        let startedAt = Date()
        let derivedDataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessDerivedData-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: derivedDataURL) }
        // Listing also fetches the project's Swift packages into the run's folder, outside the sandbox (it needs the
        // network; SwiftPM evaluates the manifests in its own sandbox). Build and test then use only that copy.
        let listResult = try await runner.run(
            kind: .xcodeBuild,
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcodebuild", "-list", "-json"] + container.selectorArguments
                + ["-clonedSourcePackagesDirPath", derivedDataURL.appendingPathComponent("SourcePackages").path],
            currentDirectoryURL: rootURL,
            environment: environment
        )
        guard listResult.exitCode == 0 else {
            return ProjectValidationReport(
                startedAt: startedAt,
                finishedAt: .now,
                checks: [failedDiscoveryCheck(container: container, result: listResult)]
            )
        }

        let metadata = XcodeSchemeParser.metadata(from: listResult.output)
        let schemes = metadata?.schemes ?? []
        guard let scheme = XcodeProjectSelection.preferredScheme(
            from: schemes,
            container: container
        ) else {
            throw ProjectValidationError.xcodeSchemeUnavailable(container.name)
        }
        let buildResult = try await runner.run(
            kind: .xcodeBuild,
            executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: isolated(buildArguments(
                container: container,
                scheme: scheme,
                derivedDataURL: derivedDataURL
            ), derivedDataURL: derivedDataURL),
            currentDirectoryURL: rootURL,
            environment: isolatedEnvironment(environment, derivedDataURL: derivedDataURL)
        )
        let buildContext = "[Local Factory] \(container.relativePath) / scheme: \(scheme) / Debug / 署名なし / 隔離(通信なし)"
        let buildOutput = buildResult.output.isEmpty
            ? buildContext
            : "\(buildContext)\n\n\(buildResult.output)"
        let buildCheck = ProjectValidationCheck(
            kind: .xcodeBuild,
            succeeded: buildResult.exitCode == 0,
            exitCode: buildResult.exitCode,
            output: buildOutput,
            outputWasTruncated: buildResult.outputWasTruncated,
            duration: buildResult.duration
        )
        var checks = [buildCheck]
        if buildCheck.succeeded, metadata?.hasTestTarget == true {
            checks.append(
                try await testCheck(
                    rootURL: rootURL,
                    container: container,
                    scheme: scheme,
                    derivedDataURL: derivedDataURL,
                    environment: environment
                )
            )
        }
        return ProjectValidationReport(
            startedAt: startedAt,
            finishedAt: .now,
            checks: checks
        )
    }

    private func xcodeEnvironment(rootURL: URL) async throws -> [String: String] {
        let environment: [String: String]
        do {
            environment = try await environmentResolver.environment(
                for: "xcodebuild",
                currentDirectoryURL: rootURL
            )
        } catch {
            throw ProjectValidationError.xcodeUnavailable
        }

        let setupResult = try await runner.run(
            kind: .xcodeBuild,
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcodebuild", "-checkFirstLaunchStatus"],
            currentDirectoryURL: rootURL,
            environment: environment
        )
        guard setupResult.exitCode == 0 else {
            throw ProjectValidationError.xcodeSetupRequired
        }
        return environment
    }

    /// `sandbox-exec -p <profile> /usr/bin/xcrun xcodebuild …` with the packages already fetched into the run's folder.
    func isolated(_ arguments: [String], derivedDataURL: URL) -> [String] {
        ["-p", XcodeIsolation.profile(workDirectory: derivedDataURL), "/usr/bin/xcrun"] + arguments
            + ["-clonedSourcePackagesDirPath", derivedDataURL.appendingPathComponent("SourcePackages").path,
               "-disableAutomaticPackageResolution"] + XcodeIsolation.buildSettings
    }

    private func isolatedEnvironment(_ environment: [String: String], derivedDataURL: URL) -> [String: String] {
        let temporary = derivedDataURL.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        var copy = environment
        copy["TMPDIR"] = temporary.path + "/"
        return copy
    }

    private func buildArguments(
        container: XcodeProjectContainer,
        scheme: String,
        derivedDataURL: URL
    ) -> [String] {
        ["xcodebuild"]
            + container.selectorArguments
            + [
                "-scheme", scheme,
                "-configuration", "Debug",
                "-derivedDataPath", derivedDataURL.path,
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "build"
            ]
    }

    private func testCheck(
        rootURL: URL,
        container: XcodeProjectContainer,
        scheme: String,
        derivedDataURL: URL,
        environment: [String: String]
    ) async throws -> ProjectValidationCheck {
        let devices: [SimulatorDevice]
        do {
            devices = try await simulatorService.listDevices()
        } catch {
            return unavailableTestCheck("Simulatorを確認できませんでした：\(error.localizedDescription)")
        }
        guard let destination = XcodeTestDestinationSelector.preferred(from: devices) else {
            return unavailableTestCheck("利用できるiPhone Simulatorがありません。XcodeのComponentsを確認してください。")
        }
        let result = try await runner.run(
            kind: .xcodeTest,
            executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: isolated(testArguments(
                container: container,
                scheme: scheme,
                derivedDataURL: derivedDataURL,
                destinationID: destination.id
            ), derivedDataURL: derivedDataURL),
            currentDirectoryURL: rootURL,
            environment: isolatedEnvironment(environment, derivedDataURL: derivedDataURL)
        )
        let context = "[Local Factory] \(destination.name)（\(destination.runtimeName)）でテスト(隔離・通信なし)"
        return ProjectValidationCheck(
            kind: .xcodeTest,
            succeeded: result.exitCode == 0,
            exitCode: result.exitCode,
            output: result.output.isEmpty ? context : "\(context)\n\n\(result.output)",
            outputWasTruncated: result.outputWasTruncated,
            duration: result.duration
        )
    }

    private func testArguments(
        container: XcodeProjectContainer,
        scheme: String,
        derivedDataURL: URL,
        destinationID: String
    ) -> [String] {
        ["xcodebuild"]
            + container.selectorArguments
            + [
                "-scheme", scheme,
                "-configuration", "Debug",
                "-destination", "id=\(destinationID)",
                "-derivedDataPath", derivedDataURL.path,
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "test"
            ]
    }

    private func unavailableTestCheck(_ message: String) -> ProjectValidationCheck {
        ProjectValidationCheck(
            kind: .xcodeTest,
            succeeded: false,
            exitCode: 1,
            output: "[Harness] \(message)",
            outputWasTruncated: false,
            duration: 0
        )
    }

    private func failedDiscoveryCheck(
        container: XcodeProjectContainer,
        result: ValidationCommandResult
    ) -> ProjectValidationCheck {
        let message = "[Local Factory] \(container.relativePath)のscheme一覧を取得できませんでした。"
        return ProjectValidationCheck(
            kind: .xcodeBuild,
            succeeded: false,
            exitCode: result.exitCode,
            output: result.output.isEmpty ? message : "\(message)\n\n\(result.output)",
            outputWasTruncated: result.outputWasTruncated,
            duration: result.duration
        )
    }
}
