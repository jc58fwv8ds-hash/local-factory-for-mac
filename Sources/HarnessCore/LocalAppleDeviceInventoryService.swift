import Foundation

struct LocalAppleDeviceInventoryService: Sendable {
    private let environmentResolver = XcodeCommandEnvironmentResolver()
    private let runner = BoundedCommandRunner(
        timeout: .seconds(45),
        maximumOutputBytes: 2_000_000
    )
    private static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    func listDevices() async throws -> [PhysicalAppleDevice] {
        let environment: [String: String]
        do {
            environment = try await environmentResolver.environment(for: "devicectl")
        } catch {
            throw PhysicalDeviceServiceError.xcodeUnavailable
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessDevices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let result: BoundedCommandResult
        do {
            result = try await runner.run(
                executableURL: Self.xcrunURL,
                arguments: [
                    "devicectl", "list", "devices", "--quiet",
                    "--json-output", outputURL.path
                ],
                environment: environment
            )
        } catch BoundedCommandError.timedOut {
            throw PhysicalDeviceServiceError.timedOut
        } catch {
            throw PhysicalDeviceServiceError.deviceServiceUnavailable
        }

        guard result.exitCode == 0,
              let data = try? Data(contentsOf: outputURL, options: .mappedIfSafe),
              data.count <= 2_000_000 else {
            throw PhysicalDeviceServiceError.deviceServiceUnavailable
        }
        return PhysicalDeviceParser.devices(from: data)
    }
}
