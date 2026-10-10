import Foundation
@testable import HarnessCore
import Testing

struct CommandOutputMonitorTests {
    @Test func cancellationDoesNotDrainRemainingLog() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let monitor = CommandOutputMonitor(file: file)
        let output = ObservedOutput()
        let task = Task {
            await monitor.run { text in
                await output.append(text)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await task.value
        #expect(await output.bytes == 8_192)
    }

    @Test func finishDrainsOnlyCapturedBoundary() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let monitor = CommandOutputMonitor(file: file)
        try await monitor.finish()
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("late descendant output".utf8))
        try writer.close()
        let output = ObservedOutput()
        await monitor.run { await output.append($0) }
        #expect(await output.bytes == 20_000)
    }

    @Test func normalCommandDeliversFinalProgress() async throws {
        let output = ObservedOutput()
        let result = try await BoundedCommandRunner(timeout: .seconds(3)).run(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print 'x' x 20000;"],
            onOutput: { await output.append($0) }
        )
        #expect(result.exitCode == 0)
        #expect(await output.bytes == 20_000)
    }

    @Test func timeoutCancelsProgressObserverAfterProcessExit() async {
        let started = ContinuousClock.now
        await #expect(throws: BoundedCommandError.timedOut) {
            try await BoundedCommandRunner(timeout: .milliseconds(300)).run(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["progress"],
                onOutput: { _ in try? await Task.sleep(for: .seconds(3)) }
            )
        }
        #expect(started.duration(to: .now) < .seconds(2))
    }

    private func fixture() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessMonitor-\(UUID()).log")
        try Data(repeating: 65, count: 20_000).write(to: file)
        return file
    }
}

private actor ObservedOutput {
    var bytes = 0
    func append(_ text: String) { bytes += text.utf8.count }
}
