import Foundation
import Testing
@testable import HarnessApp

struct HarnessAppEnvironmentTests {
    @Test func dogfoodBundleUsesSeparateSupportFolder() {
        #expect(HarnessAppEnvironment.supportFolderName(
            bundleIdentifier: "local.harness.creation-studio.dogfood") == "HarnessCandidate")
        #expect(HarnessAppEnvironment.supportFolderName(
            bundleIdentifier: "local.harness.creation-studio") == "Harness")
    }

    @Test func fixtureWorkspaceIsAcceptedOnlyInsideTheTemporaryRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Harness-GUI-Fixture-Policy", isDirectory: true)
        let accepted = root.appendingPathComponent("workspace.json")

        #expect(HarnessAppEnvironment.fixtureWorkspaceURL(
            environment: [HarnessAppEnvironment.fixtureWorkspaceKey: accepted.path],
            temporaryDirectory: FileManager.default.temporaryDirectory
        ) == accepted.standardizedFileURL.resolvingSymlinksInPath())
        #expect(HarnessAppEnvironment.fixtureWorkspaceURL(
            environment: [HarnessAppEnvironment.fixtureWorkspaceKey: "/Users/example/workspace.json"],
            temporaryDirectory: FileManager.default.temporaryDirectory
        ) == nil)
        #expect(HarnessAppEnvironment.fixtureWorkspaceURL(
            environment: [HarnessAppEnvironment.fixtureWorkspaceKey: "relative/workspace.json"],
            temporaryDirectory: FileManager.default.temporaryDirectory
        ) == nil)
        #expect(HarnessAppEnvironment.fixtureWorkspaceURL(
            environment: [HarnessAppEnvironment.fixtureWorkspaceKey: root.appendingPathComponent("other.json").path],
            temporaryDirectory: FileManager.default.temporaryDirectory
        ) == nil)
    }
}
