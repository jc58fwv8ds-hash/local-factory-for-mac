import Foundation
import HarnessCore
import Testing

struct SimulatorValidationConfigurationTests {
    // All configurations are rejected before probing Xcode or starting a simulator.
    @Test(arguments: ["inside-source", "existing-output", "parent-project", "option-scheme"])
    func unsafeConfigurationIsRejectedWithoutTools(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessSimulatorConfig-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("App.xcodeproj"),
                                               withIntermediateDirectories: true)
        let artifacts = mode == "inside-source" ? source.appendingPathComponent("output") : root.appendingPathComponent("output")
        if mode == "existing-output" {
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        }
        let service = XcodeSimulatorValidationService(
            project: mode == "parent-project" ? "../App.xcodeproj" : "App.xcodeproj",
            scheme: mode == "option-scheme" ? "-help" : "App", deviceID: UUID(), artifacts: artifacts
        )
        await #expect(throws: XcodeSimulatorValidationError.self) {
            try await service.validate(rootPath: source.path)
        }
        #expect(FileManager.default.fileExists(atPath: artifacts.path) == (mode == "existing-output"))
    }
}
