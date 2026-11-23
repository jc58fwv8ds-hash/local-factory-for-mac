import Foundation
@testable import HarnessApp
import Testing

struct DeploymentTargetRaiseTests {
    @Test func theMinimumIOSGoesUpToWhatTheCodeNeeds() throws {
        #expect(DeploymentTargetRaise.required(["'SpeechAnalyzer' is only available in iOS 26 or newer",
                                                "'X' is only available in iOS 26.1 or newer"]) == "26.1")
        #expect(DeploymentTargetRaise.required(["cannot find 'x' in scope"]) == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("App.xcodeproj/project.pbxproj")
        try "a = {IPHONEOS_DEPLOYMENT_TARGET = 17.0;}; b = {IPHONEOS_DEPLOYMENT_TARGET = 17.0;};".write(to: file, atomically: true, encoding: .utf8)
        #expect(DeploymentTargetRaise.raise(root: root.path, to: "26.0", phones: ["iOS 25.1(iPhone15,2)"]) == nil)
        #expect(DeploymentTargetRaise.raise(root: root.path, to: "26.0", phones: ["iOS 27.2.1(iPhone15,2)"]) == "17.0")
        #expect(try String(contentsOf: file, encoding: .utf8) == "a = {IPHONEOS_DEPLOYMENT_TARGET = 26.0;}; b = {IPHONEOS_DEPLOYMENT_TARGET = 26.0;};")
        try? FileManager.default.removeItem(at: root)
    }
}
