import Foundation
import HarnessCore

enum ProjectValidationChecks {
    static func run() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessValidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makePackage(at: rootURL)

        // The checks run inside Codex's own sandbox, so nested SwiftPM sandboxing
        // is unavailable here. Production validation keeps SwiftPM's sandbox on.
        let service = SwiftPackageValidationService(disableSwiftPMSandbox: true)
        let packageSupport = await service.support(rootPath: rootURL.path)
        try expect(
            packageSupport?.system == .swiftPackage,
            "Swift Package support discovery missed Package.swift"
        )
        let unsupportedURL = rootURL.appendingPathComponent("Unsupported", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unsupportedURL,
            withIntermediateDirectories: true
        )
        let emptyFolderSupport = await service.support(rootPath: unsupportedURL.path)
        try expect(
            emptyFolderSupport == nil,
            "Support discovery accepted a folder without Package.swift"
        )
        print("✓ Swift Package support is detected before validation")

        let validPackageReport = try await service.validate(rootPath: rootURL.path)
        let validationDetails = validPackageReport.checks.map {
            "\($0.kind.rawValue) exit=\($0.exitCode): \($0.output)"
        }.joined(separator: "\n")
        let buildCheck = validPackageReport.checks.first { $0.kind == .build }
        let testCheck = validPackageReport.checks.first { $0.kind == .test }
        let testResultIsHonest = testCheck?.succeeded == true
            || testCheck?.output.contains("テストの実行を確認できませんでした") == true
        try expect(
            validPackageReport.checks.map(\.kind) == [.build, .test]
                && buildCheck?.succeeded == true
                && testCheck?.exitCode == 0
                && testResultIsHonest,
            "Swift Package build and test validation failed\n\(validationDetails)"
        )
        print("✓ Swift Package validation verifies that tests actually execute")

        try Data("public func answer( { 42 }".utf8).write(
            to: rootURL.appendingPathComponent("Sources/Fixture/Fixture.swift"),
            options: .atomic
        )
        let failedReport = try await service.validate(rootPath: rootURL.path)
        try expect(
            !failedReport.succeeded
                && failedReport.checks.count == 1
                && failedReport.checks[0].kind == .build
                && !failedReport.checks[0].succeeded,
            "Failed builds must stop validation before tests"
        )

        var project = HarnessProject.starter
        ProjectValidationWorkflow.completed(report: failedReport, in: &project)
        try expect(
            project.activity.first?.kind == .warning
                && project.currentActivity.contains("確認"),
            "Failed validation did not update project activity"
        )
        ProjectValidationWorkflow.completed(report: passingReport(), in: &project)
        try expect(
            project.activity.first?.kind == .verification
                && project.currentActivity.contains("合格"),
            "Successful validation did not update project activity"
        )
        print("✓ Validation failures stop tests and update project state consistently")
    }

    private static func passingReport() -> ProjectValidationReport {
        let check = ProjectValidationCheck(
            kind: .build,
            succeeded: true,
            exitCode: 0,
            output: "ok",
            outputWasTruncated: false,
            duration: 0.1
        )
        return ProjectValidationReport(
            startedAt: .now,
            finishedAt: .now,
            checks: [check]
        )
    }

    private static func makePackage(at rootURL: URL) throws {
        let sourceDirectory = rootURL
            .appendingPathComponent("Sources/Fixture", isDirectory: true)
        let testDirectory = rootURL
            .appendingPathComponent("Tests/FixtureTests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )

        let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "Fixture",
            platforms: [.macOS(.v14)],
            products: [.library(name: "Fixture", targets: ["Fixture"])],
            targets: [
                .target(name: "Fixture"),
                .testTarget(
                    name: "FixtureTests",
                    dependencies: ["Fixture"],
                    swiftSettings: [
                        .unsafeFlags([
                            "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                        ])
                    ],
                    linkerSettings: [
                        .unsafeFlags([
                            "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                            "-Xlinker", "-rpath",
                            "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                            "-Xlinker", "-rpath",
                            "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                        ])
                    ]
                )
            ]
        )
        """
        try Data(manifest.utf8).write(
            to: rootURL.appendingPathComponent("Package.swift"),
            options: .atomic
        )
        try Data("public func answer() -> Int { 42 }\n".utf8).write(
            to: sourceDirectory.appendingPathComponent("Fixture.swift"),
            options: .atomic
        )
        let test = """
        import Testing
        @testable import Fixture

        @Test func answerIsFortyTwo() {
            #expect(answer() == 42)
        }
        """
        try Data(test.utf8).write(
            to: testDirectory.appendingPathComponent("FixtureTests.swift"),
            options: .atomic
        )
    }
}
