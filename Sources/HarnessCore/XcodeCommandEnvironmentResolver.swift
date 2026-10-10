import Foundation

enum XcodeCommandEnvironmentError: Error, Equatable, Sendable {
    case unavailable
}

struct XcodeCommandEnvironmentResolver: Sendable {
    private let toolchainLocator = XcodeToolchainLocator()
    private let runner = BoundedCommandRunner(
        timeout: .seconds(15),
        maximumOutputBytes: 8_000
    )

    func environment(
        for tool: String,
        currentDirectoryURL: URL? = nil
    ) async throws -> [String: String] {
        guard Self.allowedTools.contains(tool) else {
            throw XcodeCommandEnvironmentError.unavailable
        }

        if tool == "swift",
           let developerDirectory = toolchainLocator.standardDeveloperDirectory() {
            let preferred = ["DEVELOPER_DIR": developerDirectory.path]
            if try await probe(
                tool: tool,
                currentDirectoryURL: currentDirectoryURL,
                environment: preferred
            ) {
                return preferred
            }
        }

        if try await probe(
            tool: tool,
            currentDirectoryURL: currentDirectoryURL,
            environment: [:]
        ) {
            return [:]
        }

        guard let developerDirectory = toolchainLocator.standardDeveloperDirectory() else {
            throw XcodeCommandEnvironmentError.unavailable
        }
        let fallback = ["DEVELOPER_DIR": developerDirectory.path]
        guard try await probe(
            tool: tool,
            currentDirectoryURL: currentDirectoryURL,
            environment: fallback
        ) else {
            throw XcodeCommandEnvironmentError.unavailable
        }
        return fallback
    }

    private func probe(
        tool: String,
        currentDirectoryURL: URL?,
        environment: [String: String]
    ) async throws -> Bool {
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--find", tool],
            currentDirectoryURL: currentDirectoryURL,
            environment: environment
        )
        return result.exitCode == 0
    }

    private static let allowedTools = Set(["swift", "xcodebuild", "simctl", "devicectl"])
}
