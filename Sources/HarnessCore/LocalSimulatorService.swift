import Foundation

public struct LocalSimulatorService: SimulatorProviding, Sendable {
    private let environmentResolver = XcodeCommandEnvironmentResolver()
    private let runner = BoundedCommandRunner()
    private static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    private static let maximumScreenshotBytes = 50_000_000

    public init() {}

    public func listDevices() async throws -> [SimulatorDevice] {
        let environment = try await simulatorEnvironment()
        let result = try await run(
            arguments: ["simctl", "list", "devices", "available", "--json"],
            environment: environment
        )
        guard result.exitCode == 0 else {
            throw SimulatorServiceError.serviceUnavailable(summary(of: result.output))
        }
        return SimulatorDeviceParser.devices(from: result.output)
    }

    public func boot(_ device: SimulatorDevice) async throws {
        let identifier = try validatedIdentifier(device.id)
        guard device.state != .booted else { return }
        let environment = try await simulatorEnvironment()
        let bootResult = try await run(
            arguments: ["simctl", "boot", identifier],
            environment: environment
        )
        guard bootResult.exitCode == 0 else {
            throw SimulatorServiceError.serviceUnavailable(summary(of: bootResult.output))
        }
        let statusResult = try await run(
            arguments: ["simctl", "bootstatus", identifier, "-b"],
            environment: environment
        )
        guard statusResult.exitCode == 0 else {
            throw SimulatorServiceError.serviceUnavailable(summary(of: statusResult.output))
        }
    }

    public func captureScreenshot(of device: SimulatorDevice) async throws -> SimulatorScreenshot {
        guard device.state == .booted else {
            throw SimulatorServiceError.deviceNotBooted
        }
        let identifier = try validatedIdentifier(device.id)
        let environment = try await simulatorEnvironment()
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessSimulator-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let result = try await run(
            arguments: ["simctl", "io", identifier, "screenshot", imageURL.path],
            environment: environment
        )
        guard result.exitCode == 0,
              let data = try? Data(contentsOf: imageURL, options: .mappedIfSafe),
              data.count <= Self.maximumScreenshotBytes,
              SimulatorDeviceParser.isPNG(data) else {
            throw SimulatorServiceError.screenshotInvalid
        }
        return SimulatorScreenshot(device: device, pngData: data)
    }

    private func simulatorEnvironment() async throws -> [String: String] {
        do {
            return try await environmentResolver.environment(for: "simctl")
        } catch {
            throw SimulatorServiceError.xcodeUnavailable
        }
    }

    private func run(
        arguments: [String],
        environment: [String: String]
    ) async throws -> BoundedCommandResult {
        do {
            return try await runner.run(
                executableURL: Self.xcrunURL,
                arguments: arguments,
                environment: environment
            )
        } catch BoundedCommandError.unavailable {
            throw SimulatorServiceError.xcodeUnavailable
        } catch BoundedCommandError.timedOut {
            throw SimulatorServiceError.timedOut
        }
    }

    private func validatedIdentifier(_ value: String) throws -> String {
        guard let identifier = UUID(uuidString: value) else {
            throw SimulatorServiceError.invalidDevice
        }
        return identifier.uuidString
    }

    private func summary(of output: String) -> String {
        guard !output.isEmpty else { return "" }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(3).joined(separator: " ").prefix(600).description
    }
}
