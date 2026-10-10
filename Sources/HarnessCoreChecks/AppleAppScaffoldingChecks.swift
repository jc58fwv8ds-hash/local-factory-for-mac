import Foundation
import HarnessCore

enum AppleAppScaffoldingChecks {
    static func run() throws {
        try checkManagedProjectDirectory()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessScaffold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }

        let request = AppleAppScaffoldRequest(
            parentDirectoryPath: parent.path,
            productName: "HarnessRemote",
            displayName: "Harness Remote",
            organizationIdentifier: "local.harness"
        )
        let scaffolder = AppleAppScaffolder()
        let result = try scaffolder.create(request)

        try expect(
            result.createdRelativePaths.count == 10
                && FileManager.default.fileExists(
                    atPath: URL(fileURLWithPath: result.projectPath)
                        .appendingPathComponent("project.pbxproj").path
                )
                && FileManager.default.fileExists(
                    atPath: URL(fileURLWithPath: result.rootPath)
                        .appendingPathComponent("HarnessRemote/ContentView.swift").path
                ),
            "iPhone project scaffold did not create its bounded template"
        )

        let projectText = try String(
            contentsOf: URL(fileURLWithPath: result.projectPath)
                .appendingPathComponent("project.pbxproj"),
            encoding: .utf8
        )
        try expect(
            projectText.contains("com.apple.product-type.application")
                && projectText.contains("TARGETED_DEVICE_FAMILY = 1")
                && projectText.contains("local.harness.harnessremote")
                && projectText.contains("PBXFileSystemSynchronizedRootGroup")
                && projectText.contains("membershipExceptions = (Info.plist)"),
            "Generated Xcode project is not an iPhone application target"
        )

        let infoPlistText = try String(
            contentsOf: URL(fileURLWithPath: result.rootPath)
                .appendingPathComponent("HarnessRemote/Info.plist"),
            encoding: .utf8
        )
        try expect(
            infoPlistText.contains("$(PRODUCT_BUNDLE_IDENTIFIER)")
                && infoPlistText.contains("$(EXECUTABLE_NAME)")
                && infoPlistText.contains("CFBundlePackageType"),
            "Generated app metadata cannot be installed on a device or Simulator"
        )

        try expectThrows("Existing destinations must never be overwritten") {
            _ = try scaffolder.create(request)
        }
        try expectThrows("Unsafe product names must be rejected") {
            _ = try scaffolder.create(
                AppleAppScaffoldRequest(
                    parentDirectoryPath: parent.path,
                    productName: "../Remote",
                    displayName: "Remote"
                )
            )
        }
        try expectThrows("Invalid organization identifiers must be rejected") {
            _ = try scaffolder.create(
                AppleAppScaffoldRequest(
                    parentDirectoryPath: parent.path,
                    productName: "RemoteTwo",
                    displayName: "Remote",
                    organizationIdentifier: "invalid"
                )
            )
        }

        print("✓ iPhone Xcode scaffolding is fixed, bounded, and never overwrites a destination")
    }

    private static func checkManagedProjectDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessManagedProjectCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ManagedProjectDirectory(baseDirectory: root)
        let first = try provider.prepare()
        let second = try provider.prepare()
        try expect(
            first == second
                && first.lastPathComponent == "Projects"
                && FileManager.default.fileExists(atPath: first.path),
            "Harness-managed project storage must be idempotent and isolated"
        )
    }
}
