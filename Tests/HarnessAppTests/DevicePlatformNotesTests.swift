import Foundation
@testable import HarnessApp
import Testing

struct DevicePlatformNotesTests {
    @Test func theProjectsDeploymentTargetIsRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("platform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try "buildSettings = {IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos;}"
            .write(to: root.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        #expect(DevicePlatformNotes.deploymentTarget(root: root.path) == "17.0")
        #expect(DevicePlatformNotes.notes(root: root.path)?.contains("最低 iOS(IPHONEOS_DEPLOYMENT_TARGET): 17.0") == true)
        #expect(DevicePlatformNotes.notes(root: FileManager.default.temporaryDirectory.path) == nil)
        try? FileManager.default.removeItem(at: root)
    }
}
