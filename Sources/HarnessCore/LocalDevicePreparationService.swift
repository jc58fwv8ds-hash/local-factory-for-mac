import Foundation

/// Read-only device queries; never pairs, changes settings, signs, installs, or retries.
public struct LocalDevicePreparationService: DevicePreparationProviding {
    private let resolver = XcodeCommandEnvironmentResolver()
    private let runner = BoundedCommandRunner(timeout: .seconds(15), maximumOutputBytes: 2_000_000)

    public init() {}

    public func inspect(deviceIdentifier: String) async throws -> DevicePreparationSnapshot {
        guard UUID(uuidString: deviceIdentifier) != nil else { throw DevicePreparationError.invalidIdentifier }
        try Task.checkCancellation()
        let started = Date()
        let environment: [String: String]
        do { environment = try await resolver.environment(for: "devicectl") }
        catch {
            try Task.checkCancellation()
            return DevicePreparationSnapshot(deviceIdentifier: deviceIdentifier, observedAt: started,
                                             detailsFailure: .toolUnavailable)
        }
        var details = DevicePreparationSnapshot(deviceIdentifier: deviceIdentifier, observedAt: started)
        do {
            let data = try await query("details", identifier: deviceIdentifier, environment: environment)
            details = try DevicePreparationParser.details(data, identifier: deviceIdentifier, observedAt: started)
        } catch {
            try Task.checkCancellation()
            return DevicePreparationSnapshot(deviceIdentifier: deviceIdentifier, observedAt: started,
                                             detailsFailure: failure(error))
        }
        // Do not wait for another command on an unavailable/unprepared connection.
        guard details.tunnel == .met, details.ddiServices == .met else { return details }
        var passcode: DevicePreparationState = .unknown
        var lockFailure: DevicePreparationFailure?
        do {
            let data = try await query("lockState", identifier: deviceIdentifier, environment: environment)
            passcode = try DevicePreparationParser.lock(data, identifier: deviceIdentifier)
        } catch {
            try Task.checkCancellation()
            lockFailure = failure(error)
        }
        try Task.checkCancellation()
        return DevicePreparationSnapshot(deviceIdentifier: deviceIdentifier, observedAt: started,
            pairing: details.pairing, tunnel: details.tunnel, developerMode: details.developerMode,
            ddiServices: details.ddiServices, passcode: passcode, lockFailure: lockFailure)
    }

    private func query(_ command: String, identifier: String, environment: [String: String]) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessDeviceProbe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("response.json")
        let result = try await runner.run(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "device", "info", command, "--device", identifier,
                        "--timeout", "10", "--quiet", "--json-output", output.path], environment: environment)
        try Task.checkCancellation()
        guard result.exitCode == 0 else { throw DevicePreparationFailure.commandFailed }
        let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 2_000_000 else { throw DevicePreparationFailure.invalidResponse }
        return try Data(contentsOf: output)
    }

    private func failure(_ error: Error) -> DevicePreparationFailure {
        if let failure = error as? DevicePreparationFailure { return failure }
        if case BoundedCommandError.timedOut = error { return .timedOut }
        return .invalidResponse
    }
}
