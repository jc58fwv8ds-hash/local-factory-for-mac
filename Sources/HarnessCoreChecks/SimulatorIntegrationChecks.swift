import Foundation
import HarnessCore

enum SimulatorIntegrationChecks {
    static func run() async throws {
        let service = LocalSimulatorService()
        let devices = try await service.listDevices()
        let preferredDevice = devices.first {
            $0.runtimeName.hasPrefix("iOS ")
                && $0.name.hasPrefix("iPhone")
        }
        let device = try require(preferredDevice)

        try await service.boot(device)
        let refreshedDevices = try await service.listDevices()
        let bootedDevice = try require(
            refreshedDevices.first {
                $0.id == device.id && $0.state == .booted
            }
        )
        let screenshot = try await service.captureScreenshot(of: bootedDevice)
        try expect(
            SimulatorDeviceParser.isPNG(screenshot.pngData)
                && screenshot.pngData.count <= 50_000_000,
            "Real Simulator screenshot did not stay inside the PNG safety boundary"
        )

        if let outputPath = ProcessInfo.processInfo.environment[
            "HARNESS_SIMULATOR_SCREENSHOT_PATH"
        ], !outputPath.isEmpty {
            try screenshot.pngData.write(
                to: URL(fileURLWithPath: outputPath),
                options: .atomic
            )
        }
        print(
            "✓ Real Simulator list, boot, bootstatus, and screenshot succeeded: "
                + "\(bootedDevice.name) / \(bootedDevice.runtimeName)"
        )
    }
}
