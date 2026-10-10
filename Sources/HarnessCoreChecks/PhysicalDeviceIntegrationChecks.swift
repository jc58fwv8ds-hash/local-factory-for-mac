import Foundation
import HarnessCore

enum PhysicalDeviceIntegrationChecks {
    static func run() async throws {
        let service = LocalPhysicalDeviceService()
        let devices = try await service.listDevices()
        try expect(
            devices.allSatisfy { !$0.name.isEmpty && !$0.modelName.isEmpty },
            "Physical device integration must return only bounded display metadata"
        )
        print("✓ Physical device integration found \(devices.count) available iPhone(s)")

        if let rootPath = ProcessInfo.processInfo.environment["HARNESS_DEVICE_INSPECTION_ROOT"],
           let device = devices.first {
            let readiness = try await service.inspect(rootPath: rootPath, device: device)
            try expect(
                readiness.device.id == device.id,
                "Physical device inspection must preserve the in-memory device selection"
            )
            let state = readiness.canRun
                ? "ready"
                : readiness.requirements.map(\.title).joined(separator: ", ")
            print("✓ Physical device signing inspection completed: \(state)")
        }
    }
}
