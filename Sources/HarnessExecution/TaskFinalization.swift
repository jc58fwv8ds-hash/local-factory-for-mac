public enum TaskFinalization {
    /// Await finalization on every ordinary success/error exit, preserving original error.
    /// Host termination is not an ordinary exit and remains a separate recovery concern.
    public static func run<T>(operation: () async throws -> T, finalize: () async -> Void) async rethrows -> T {
        do {
            let result = try await operation()
            await finalize()
            return result
        } catch {
            await finalize()
            throw error
        }
    }
}
