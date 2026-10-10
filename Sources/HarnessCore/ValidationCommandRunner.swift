import Foundation

typealias ValidationCommandResult = BoundedCommandResult

struct ValidationCommandRunner: Sendable {
    private let runner = BoundedCommandRunner()

    func run(
        kind: ProjectValidationKind,
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:]
    ) async throws -> ValidationCommandResult {
        do {
            return try await runner.run(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                environment: environment
            )
        } catch BoundedCommandError.unavailable {
            throw ProjectValidationError.commandUnavailable
        } catch BoundedCommandError.timedOut {
            throw ProjectValidationError.timedOut(kind)
        }
    }
}
