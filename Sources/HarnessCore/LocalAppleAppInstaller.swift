import Foundation

struct LocalAppleAppInstaller: Sendable {
    let preparationProvider: any DevicePreparationProviding

    init(preparationProvider: any DevicePreparationProviding = LocalDevicePreparationService()) {
        self.preparationProvider = preparationProvider
    }
    private let locator = XcodeProjectLocator()
    private let environmentResolver = XcodeCommandEnvironmentResolver()
    private let runner = BoundedCommandRunner(
        timeout: .seconds(180),
        maximumOutputBytes: 2_000_000
    )
    private static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    func install(
        _ app: InstallableAppleApp,
        on device: PhysicalAppleDevice,
        onStage: @escaping @Sendable (AppleAppInstallStage) async -> Void
    ) async throws -> AppleAppInstallReport {
        guard let selected = app.configuration(for: device.platform) else {
            throw AppleAppLibraryError.incompatibleDevice
        }
        try validateIdentifier(device.deviceIdentifier)
        try validateIdentifier(device.destinationIdentifier)

        let rootURL = URL(fileURLWithPath: app.source.rootPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard locator.locate(rootPath: rootURL.path) == app.container else {
            throw AppleAppLibraryError.invalidSelection
        }
        let derivedDataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessAppInstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: derivedDataURL) }

        await onStage(.preparing)
        let environment = try await xcodeEnvironment()
        let setup = try await run(
            ["xcodebuild", "-checkFirstLaunchStatus"],
            rootURL: rootURL,
            environment: environment
        )
        guard setup.exitCode == 0 else { throw AppleAppLibraryError.xcodeUnavailable }

        let settings = try await run(
            settingsArguments(
                app: app,
                configuration: selected,
                device: device,
                derivedDataURL: derivedDataURL
            ),
            rootURL: rootURL,
            environment: environment
        )
        guard settings.exitCode == 0,
              let current = AppleAppBuildSettingsParser.configuration(
                from: settings.output,
                requestedPlatform: device.platform,
                scheme: selected.scheme
              ) else {
            throw AppleAppLibraryError.settingsUnavailable
        }
        let observation = try await preparationProvider.inspect(deviceIdentifier: device.deviceIdentifier)
        guard observation.isReady(for: device.deviceIdentifier) else {
            throw DevicePreparationError.notReady(observation)
        }
        try validateReadiness(configuration: current)

        await onStage(.building)
        let build = try await run(
            buildArguments(
                app: app,
                configuration: current,
                device: device,
                derivedDataURL: derivedDataURL
            ),
            rootURL: rootURL,
            environment: environment
        )
        guard build.exitCode == 0 else {
            throw AppleAppLibraryError.buildFailed(
                PhysicalDeviceBuildFailureClassifier.classify(build.output)
            )
        }

        let appURL = try builtAppURL(
            configuration: current,
            derivedDataURL: derivedDataURL
        )
        let bundleIdentifier = try verifiedBundleIdentifier(
            appURL: appURL,
            expected: current.bundleIdentifier
        )
        let deviceEnvironment = try await deviceEnvironment()

        await onStage(.installing)
        let installed = try await run(
            [
                "devicectl", "device", "install", "app",
                "--device", device.deviceIdentifier, appURL.path, "--quiet"
            ],
            rootURL: nil,
            environment: deviceEnvironment
        )
        guard installed.exitCode == 0 else {
            throw AppleAppLibraryError.installFailed(device.platform)
        }

        await onStage(.launching)
        let launched = try await run(
            [
                "devicectl", "device", "process", "launch",
                "--device", device.deviceIdentifier, bundleIdentifier,
                "--terminate-existing", "--activate", "--quiet"
            ],
            rootURL: nil,
            environment: deviceEnvironment
        )
        guard launched.exitCode == 0 else {
            throw AppleAppLibraryError.launchFailed(device.platform)
        }
        return AppleAppInstallReport(
            appName: app.displayName,
            deviceName: device.name,
            platform: device.platform
        )
    }

    private func validateReadiness(
        configuration: AppleAppBuildConfiguration
    ) throws {
        guard configuration.signingStyle == .automatic else {
            throw AppleAppLibraryError.automaticSigningRequired
        }
        guard configuration.hasDevelopmentTeam else {
            throw AppleAppLibraryError.developmentTeamRequired
        }
        guard configuration.hasUsableBundleIdentifier else {
            throw AppleAppLibraryError.bundleIdentifierRequired
        }
    }

    private func settingsArguments(
        app: InstallableAppleApp,
        configuration: AppleAppBuildConfiguration,
        device: PhysicalAppleDevice,
        derivedDataURL: URL
    ) -> [String] {
        ["xcodebuild"] + app.container.selectorArguments + [
            "-scheme", configuration.scheme,
            "-configuration", "Debug",
            "-sdk", device.platform == .iPhone ? "iphoneos" : "watchos",
            "-destination", "id=\(device.destinationIdentifier)",
            "-derivedDataPath", derivedDataURL.path,
            "-showBuildSettings", "-json"
        ]
    }

    private func buildArguments(
        app: InstallableAppleApp,
        configuration: AppleAppBuildConfiguration,
        device: PhysicalAppleDevice,
        derivedDataURL: URL
    ) -> [String] {
        ["xcodebuild"] + app.container.selectorArguments + [
            "-scheme", configuration.scheme,
            "-configuration", "Debug",
            "-destination", "id=\(device.destinationIdentifier)",
            "-derivedDataPath", derivedDataURL.path,
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
            "-hideShellScriptEnvironment",
            "build"
        ]
    }

    private func builtAppURL(
        configuration: AppleAppBuildConfiguration,
        derivedDataURL: URL
    ) throws -> URL {
        guard let directory = configuration.targetBuildDirectory,
              let product = configuration.fullProductName,
              product.hasSuffix(".app") else {
            throw AppleAppLibraryError.appProductUnavailable
        }
        let root = derivedDataURL.standardizedFileURL.resolvingSymlinksInPath()
        let appURL = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(product, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard appURL.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: appURL.path) else {
            throw AppleAppLibraryError.appProductUnavailable
        }
        return appURL
    }

    private func verifiedBundleIdentifier(appURL: URL, expected: String?) throws -> String {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              data.count <= 1_000_000,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any],
              let identifier = values["CFBundleIdentifier"] as? String,
              identifier == expected,
              identifier.count <= 255 else {
            throw AppleAppLibraryError.appProductUnavailable
        }
        return identifier
    }

    private func validateIdentifier(_ value: String) throws {
        guard (8...80).contains(value.count),
              value.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).contains($0)
              }) else { throw AppleAppLibraryError.invalidSelection }
    }

    private func xcodeEnvironment() async throws -> [String: String] {
        do {
            return try await environmentResolver.environment(for: "xcodebuild")
        } catch {
            throw AppleAppLibraryError.xcodeUnavailable
        }
    }

    private func deviceEnvironment() async throws -> [String: String] {
        do {
            return try await environmentResolver.environment(for: "devicectl")
        } catch {
            throw AppleAppLibraryError.xcodeUnavailable
        }
    }

    private func run(
        _ arguments: [String],
        rootURL: URL?,
        environment: [String: String]
    ) async throws -> BoundedCommandResult {
        do {
            return try await runner.run(
                executableURL: Self.xcrunURL,
                arguments: arguments,
                currentDirectoryURL: rootURL,
                environment: environment
            )
        } catch BoundedCommandError.timedOut {
            throw AppleAppLibraryError.timedOut
        } catch {
            throw AppleAppLibraryError.xcodeUnavailable
        }
    }
}
