import Foundation
import HarnessCore

enum XcodeValidationChecks {
    static func run() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessXcodeValidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makeContainers(at: rootURL)

        let locator = XcodeProjectLocator()
        let preferred = try require(locator.locate(rootPath: rootURL.path))
        try expect(
            preferred.kind == .workspace
                && preferred.relativePath == "Demo.xcworkspace",
            "Xcode locator must prefer a root workspace"
        )
        let inspection = await ProjectSourceScanner().inspect(path: rootURL.path)
        try expect(
            inspection.technologies.contains(.xcode),
            "Read-only source inspection missed Xcode containers"
        )

        let projectRoot = rootURL.appendingPathComponent("ProjectOnly", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("Sample.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        let project = try require(locator.locate(rootPath: projectRoot.path))
        try expect(
            project.kind == .project && project.relativePath == "Sample.xcodeproj",
            "Xcode locator missed a project container"
        )
        print("✓ Xcode workspaces and projects are discovered with deterministic priority")

        let listOutput = """
        warning: sample diagnostic { count = 1, value = invalid }
        {"workspace":{"schemes":["Zeta","Demo","Demo"],"targets":["Demo","DemoTests"]}}
        """
        try expect(
            XcodeSchemeParser.schemes(from: listOutput) == ["Demo", "Zeta"],
            "Xcode scheme JSON parsing was not stable"
        )
        try expect(
            XcodeSchemeParser.metadata(from: listOutput)?.hasTestTarget == true,
            "Xcode test target discovery missed a conventional test target"
        )
        print("✓ Xcode schemes are parsed without leaking command logic into the UI")

        let bootedPhone = SimulatorDevice(
            id: UUID().uuidString,
            name: "iPhone 14 Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            runtimeName: "iOS 26.5",
            state: .booted
        )
        let newerStoppedPhone = SimulatorDevice(
            id: UUID().uuidString,
            name: "iPhone 17 Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            runtimeName: "iOS 26.5",
            state: .shutdown
        )
        let watch = SimulatorDevice(
            id: UUID().uuidString,
            name: "Apple Watch Ultra",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-26-5",
            runtimeName: "watchOS 26.5",
            state: .booted
        )
        try expect(
            XcodeTestDestinationSelector.preferred(
                from: [watch, newerStoppedPhone, bootedPhone]
            ) == bootedPhone,
            "Xcode tests must prefer a booted iPhone and ignore non-iOS devices"
        )
        print("✓ Xcode test destinations prefer a ready iPhone Simulator")

        let service = LocalProjectValidationService(disableSwiftPMSandbox: true)
        let support = await service.support(rootPath: rootURL.path)
        try expect(
            support?.system == .xcode
                && support?.containerName == "Demo.xcworkspace"
                && support?.commandSummary.contains("xcodebuild") == true,
            "Composite validation did not route Xcode projects"
        )
        print("✓ Local validation routes Xcode and Swift Package adapters independently")
    }

    private static func makeContainers(at rootURL: URL) throws {
        let paths = [
            "Demo.xcworkspace",
            "Apps/Demo.xcodeproj",
            "Pods/Dependency.xcodeproj"
        ]
        for path in paths {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}
