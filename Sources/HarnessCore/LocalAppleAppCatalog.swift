import Foundation

struct LocalAppleAppCatalog: Sendable {
    private let locator = XcodeProjectLocator()
    private let environmentResolver = XcodeCommandEnvironmentResolver()
    private let iconLoader = AppleAppIconLoader()
    private let runner = BoundedCommandRunner(
        timeout: .seconds(90),
        maximumOutputBytes: 2_000_000
    )
    private static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    func discover(in sources: [AppleAppSource]) async throws -> [InstallableAppleApp] {
        guard !sources.isEmpty else { return [] }
        let environment: [String: String]
        do {
            environment = try await environmentResolver.environment(for: "xcodebuild")
        } catch {
            throw AppleAppLibraryError.xcodeUnavailable
        }

        var apps: [InstallableAppleApp] = []
        for source in sources.prefix(20) {
            try Task.checkCancellation()
            apps += await discover(source: source, environment: environment)
        }
        return mergeCompanions(apps).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func discover(
        source: AppleAppSource,
        environment: [String: String]
    ) async -> [InstallableAppleApp] {
        let rootURL = URL(fileURLWithPath: source.rootPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let container = locator.locate(rootPath: rootURL.path) else { return [] }

        guard let list = try? await run(
            ["xcodebuild", "-list", "-json"] + container.selectorArguments,
            rootURL: rootURL,
            environment: environment
        ), list.exitCode == 0 else { return [] }

        let schemes = XcodeSchemeParser.schemes(from: list.output).prefix(12)
        var apps: [InstallableAppleApp] = []
        for scheme in schemes {
            if let app = await inspect(
                source: source,
                rootURL: rootURL,
                container: container,
                scheme: scheme,
                environment: environment
            ) {
                apps.append(app)
            }
        }
        return apps
    }

    private func inspect(
        source: AppleAppSource,
        rootURL: URL,
        container: XcodeProjectContainer,
        scheme: String,
        environment: [String: String]
    ) async -> InstallableAppleApp? {
        var configurations: [AppleAppBuildConfiguration] = []
        for platform in AppleAppPlatform.allCases {
            guard let result = try? await run(
                settingsArguments(container: container, scheme: scheme, platform: platform),
                rootURL: rootURL,
                environment: environment
            ), result.exitCode == 0,
                  let configuration = AppleAppBuildSettingsParser.configuration(
                    from: result.output,
                    requestedPlatform: platform,
                    scheme: scheme
                  ) else { continue }
            configurations.append(configuration)
        }
        guard !configurations.isEmpty else { return nil }

        let preferred = configurations.first { $0.platform == .iPhone }
            ?? configurations[0]
        let names = configurations.compactMap(\.appIconName)
        let iconData = iconLoader.iconData(rootURL: rootURL, iconNames: names)
        return InstallableAppleApp(
            id: "\(source.projectID.uuidString.lowercased()):\(scheme)",
            source: source,
            container: container,
            scheme: scheme,
            displayName: cleanDisplayName(preferred.productName),
            configurations: configurations,
            iconData: iconData
        )
    }

    private func mergeCompanions(_ apps: [InstallableAppleApp]) -> [InstallableAppleApp] {
        var consumed = Set<String>()
        var result: [InstallableAppleApp] = []
        for app in apps where app.configuration(for: .iPhone) != nil {
            guard let phone = app.configuration(for: .iPhone) else { continue }
            let companions = apps.filter { candidate in
                candidate.id != app.id
                    && candidate.source.projectID == app.source.projectID
                    && candidate.configuration(for: .appleWatch)?.companionBundleIdentifier
                        == phone.bundleIdentifier
            }
            let watchConfigurations = companions.compactMap {
                $0.configuration(for: .appleWatch)
            }
            consumed.formUnion(companions.map(\.id))
            consumed.insert(app.id)
            result.append(
                InstallableAppleApp(
                    id: app.id,
                    source: app.source,
                    container: app.container,
                    scheme: app.scheme,
                    displayName: app.displayName,
                    configurations: app.configurations + watchConfigurations,
                    iconData: app.iconData ?? companions.compactMap(\.iconData).first
                )
            )
        }
        result += apps.filter { !consumed.contains($0.id) }
        return result
    }

    private func settingsArguments(
        container: XcodeProjectContainer,
        scheme: String,
        platform: AppleAppPlatform
    ) -> [String] {
        ["xcodebuild"] + container.selectorArguments + [
            "-scheme", scheme,
            "-configuration", "Debug",
            "-destination", "generic/platform=\(platform == .iPhone ? "iOS" : "watchOS")",
            "-showBuildSettings", "-json"
        ]
    }

    private func run(
        _ arguments: [String],
        rootURL: URL,
        environment: [String: String]
    ) async throws -> BoundedCommandResult {
        try await runner.run(
            executableURL: Self.xcrunURL,
            arguments: arguments,
            currentDirectoryURL: rootURL,
            environment: environment
        )
    }

    private func cleanDisplayName(_ value: String) -> String {
        let suffixes = [" Watch App", " WatchKit App"]
        for suffix in suffixes where value.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count))
        }
        return value
    }
}
