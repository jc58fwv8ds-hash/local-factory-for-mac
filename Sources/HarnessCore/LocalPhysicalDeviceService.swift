import Foundation

public struct LocalPhysicalDeviceService: PhysicalDeviceProviding, Sendable {
    private let locator = XcodeProjectLocator()
    private let environmentResolver = XcodeCommandEnvironmentResolver()
    private let deviceInventory = LocalAppleDeviceInventoryService()
    private let preparationProvider: any DevicePreparationProviding
    private let runner = BoundedCommandRunner(
        timeout: .seconds(180),
        maximumOutputBytes: 2_000_000
    )
    private static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    public init(preparationProvider: any DevicePreparationProviding = LocalDevicePreparationService()) {
        self.preparationProvider = preparationProvider
    }

    public func listDevices() async throws -> [PhysicalAppleDevice] {
        try await deviceInventory.listDevices().filter { $0.platform == .iPhone }
    }

    public func inspect(
        rootPath: String,
        device: PhysicalAppleDevice
    ) async throws -> PhysicalDeviceReadiness {
        let derivedDataURL = temporaryDerivedDataURL()
        defer { try? FileManager.default.removeItem(at: derivedDataURL) }
        let prepared = try await prepare(
            rootPath: rootPath,
            device: device,
            derivedDataURL: derivedDataURL
        )
        let observation = try await preparationProvider.inspect(deviceIdentifier: device.deviceIdentifier)
        return PhysicalDeviceReadinessEvaluator.evaluate(
            device: device,
            project: prepared.configuration,
            preparation: observation
        )
    }

    public func run(
        rootPath: String,
        device: PhysicalAppleDevice,
        onStage: @escaping @Sendable (PhysicalDeviceRunStage) async -> Void
    ) async throws -> PhysicalDeviceRunReport {
        try validateIdentifier(device.deviceIdentifier)
        try validateIdentifier(device.destinationIdentifier)
        let derivedDataURL = temporaryDerivedDataURL()
        defer { try? FileManager.default.removeItem(at: derivedDataURL) }

        await onStage(.preparing)
        let prepared = try await prepare(
            rootPath: rootPath,
            device: device,
            derivedDataURL: derivedDataURL
        )
        let observation = try await preparationProvider.inspect(deviceIdentifier: device.deviceIdentifier)
        guard observation.isReady(for: device.deviceIdentifier) else {
            throw DevicePreparationError.notReady(observation)
        }
        let readiness = PhysicalDeviceReadinessEvaluator.evaluate(
            device: device,
            project: prepared.configuration,
            preparation: observation
        )
        if let requirement = readiness.requirements.first {
            throw PhysicalDeviceServiceError.notReady(requirement)
        }

        await onStage(.building)
        let buildResult = try await run(
            arguments: signedBuildArguments(
                container: prepared.container,
                scheme: prepared.configuration.scheme,
                destinationIdentifier: device.destinationIdentifier,
                derivedDataURL: derivedDataURL
            ),
            currentDirectoryURL: prepared.rootURL,
            environment: prepared.environment
        )
        guard buildResult.exitCode == 0 else {
            throw PhysicalDeviceServiceError.buildFailed(
                PhysicalDeviceBuildFailureClassifier.classify(buildResult.output)
            )
        }

        let appURL = try builtAppURL(
            configuration: prepared.configuration,
            derivedDataURL: derivedDataURL
        )
        let bundleIdentifier = try bundleIdentifier(
            appURL: appURL,
            expected: prepared.configuration.bundleIdentifier
        )
        let deviceEnvironment = try await environment(for: "devicectl")

        await onStage(.installing)
        let installResult = try await run(
            arguments: [
                "devicectl", "device", "install", "app",
                "--device", device.deviceIdentifier, appURL.path, "--quiet"
            ],
            environment: deviceEnvironment
        )
        guard installResult.exitCode == 0 else {
            throw PhysicalDeviceServiceError.installFailed
        }

        await onStage(.launching)
        let launchResult = try await run(
            arguments: [
                "devicectl", "device", "process", "launch",
                "--device", device.deviceIdentifier, bundleIdentifier,
                "--terminate-existing", "--activate", "--quiet"
            ],
            environment: deviceEnvironment
        )
        guard launchResult.exitCode == 0 else {
            throw PhysicalDeviceServiceError.launchFailed
        }
        return PhysicalDeviceRunReport(
            deviceName: device.name,
            productName: prepared.configuration.productName,
            bundleIdentifier: bundleIdentifier
        )
    }

    private func prepare(
        rootPath: String,
        device: PhysicalAppleDevice,
        derivedDataURL: URL
    ) async throws -> PreparedProject {
        try validateIdentifier(device.destinationIdentifier)
        let rootURL = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard let container = locator.locate(rootPath: rootURL.path) else {
            throw PhysicalDeviceServiceError.projectUnavailable
        }
        let environment = try await environment(for: "xcodebuild")
        try await checkXcodeSetup(rootURL: rootURL, environment: environment)
        let listResult = try await run(
            arguments: ["xcodebuild", "-list", "-json"] + container.selectorArguments,
            currentDirectoryURL: rootURL,
            environment: environment
        )
        let schemes = XcodeSchemeParser.schemes(from: listResult.output)
        guard listResult.exitCode == 0,
              let scheme = XcodeProjectSelection.preferredScheme(
                  from: schemes,
                  container: container
              ) else {
            throw PhysicalDeviceServiceError.schemeUnavailable
        }
        let settingsResult = try await run(
            arguments: buildSettingsArguments(
                container: container,
                scheme: scheme,
                destinationIdentifier: device.destinationIdentifier,
                derivedDataURL: derivedDataURL
            ),
            currentDirectoryURL: rootURL,
            environment: environment
        )
        guard settingsResult.exitCode == 0,
              let configuration = XcodeSigningSettingsParser.configuration(
                  from: settingsResult.output,
                  containerName: container.name,
                  scheme: scheme
              ) else {
            throw PhysicalDeviceServiceError.settingsUnavailable
        }
        return PreparedProject(
            rootURL: rootURL,
            container: container,
            configuration: configuration,
            environment: environment
        )
    }

    private func checkXcodeSetup(
        rootURL: URL,
        environment: [String: String]
    ) async throws {
        let result = try await run(
            arguments: ["xcodebuild", "-checkFirstLaunchStatus"],
            currentDirectoryURL: rootURL,
            environment: environment
        )
        guard result.exitCode == 0 else {
            throw PhysicalDeviceServiceError.xcodeUnavailable
        }
    }

    private func environment(for tool: String) async throws -> [String: String] {
        do {
            return try await environmentResolver.environment(for: tool)
        } catch {
            throw PhysicalDeviceServiceError.xcodeUnavailable
        }
    }

    private func run(
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]
    ) async throws -> BoundedCommandResult {
        do {
            return try await runner.run(
                executableURL: Self.xcrunURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                environment: environment
            )
        } catch BoundedCommandError.timedOut {
            throw PhysicalDeviceServiceError.timedOut
        } catch {
            throw PhysicalDeviceServiceError.xcodeUnavailable
        }
    }

    private func buildSettingsArguments(
        container: XcodeProjectContainer,
        scheme: String,
        destinationIdentifier: String,
        derivedDataURL: URL
    ) -> [String] {
        ["xcodebuild"] + container.selectorArguments + [
            "-scheme", scheme,
            "-configuration", "Debug",
            "-sdk", "iphoneos",
            "-destination", "id=\(destinationIdentifier)",
            "-derivedDataPath", derivedDataURL.path,
            "-showBuildSettings", "-json"
        ]
    }

    private func signedBuildArguments(
        container: XcodeProjectContainer,
        scheme: String,
        destinationIdentifier: String,
        derivedDataURL: URL
    ) -> [String] {
        ["xcodebuild"] + container.selectorArguments + [
            "-scheme", scheme,
            "-configuration", "Debug",
            "-destination", "id=\(destinationIdentifier)",
            "-derivedDataPath", derivedDataURL.path,
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
            "-hideShellScriptEnvironment",
            "build"
        ]
    }

    private func builtAppURL(
        configuration: PhysicalDeviceProjectConfiguration,
        derivedDataURL: URL
    ) throws -> URL {
        guard let directory = configuration.targetBuildDirectory,
              let product = configuration.fullProductName,
              product.hasSuffix(".app") else {
            throw PhysicalDeviceServiceError.appProductUnavailable
        }
        let root = derivedDataURL.standardizedFileURL.resolvingSymlinksInPath()
        let appURL = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(product, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard appURL.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: appURL.path) else {
            throw PhysicalDeviceServiceError.appProductUnavailable
        }
        return appURL
    }

    private func bundleIdentifier(appURL: URL, expected: String?) throws -> String {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              data.count <= 1_000_000,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any],
              let identifier = values["CFBundleIdentifier"] as? String,
              identifier == expected,
              identifier.count <= 255 else {
            throw PhysicalDeviceServiceError.appProductUnavailable
        }
        return identifier
    }

    private func validateIdentifier(_ value: String) throws {
        guard (8...80).contains(value.count),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).contains($0)
              }) else {
            throw PhysicalDeviceServiceError.invalidDevice
        }
    }

    private func temporaryDerivedDataURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessDeviceBuild-\(UUID().uuidString)", isDirectory: true)
    }
}

private struct PreparedProject: Sendable {
    let rootURL: URL
    let container: XcodeProjectContainer
    let configuration: PhysicalDeviceProjectConfiguration
    let environment: [String: String]
}
