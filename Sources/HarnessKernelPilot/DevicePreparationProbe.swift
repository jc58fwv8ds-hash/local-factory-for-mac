import Foundation
import HarnessCore
import HarnessExecution

enum DevicePreparationProbe {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 4 else {
            throw DevicePreparationError.invalidIdentifier
        }
        // Explicit caller-selected device and receipt directory; no device mutation or model call.
        let recorder = RecordedDevicePreparationService(directory: URL(fileURLWithPath: arguments[3]))
        let observation = try await recorder.inspect(deviceIdentifier: arguments[2])
        print(observation.summary())
        for check in DevicePreparationCheck.allCases {
            print("\(check.title): \(observation.state(for: check).displayName)")
        }
        if let directory = await recorder.lastRunDirectory { print("観測記録: \(directory.path)") }
        if !observation.isReady(for: arguments[2]) { throw DevicePreparationError.notReady(observation) }
    }
}
