import Darwin
import Foundation
@testable import HarnessCore
import Testing

struct BoundedCommandRunnerTests {
    @Test func cancellationBeforeLaunchDoesNotStartProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let lifecycle = CommandProcessLifecycle(process: process)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await lifecycle.run() }
            await #expect(throws: CancellationError.self) {
                try await BoundedCommandRunner().run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: []
                )
            }
        }
        await task.value
        #expect(process.processIdentifier == 0)
    }

    @Test(arguments: [false, true])
    func termIgnoringProcessActuallyExits(cancel: Bool) async throws {
        let observation = ProcessObservation()
        // Cancellation must not race the timeout; the timeout case keeps the
        // window wide enough for perl to start under a loaded full test run.
        let timeout: Duration = cancel ? .seconds(30) : .seconds(2)
        let task = Task {
            try await BoundedCommandRunner(timeout: timeout).run(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                // The PID line is printed only after TERM is ignored. The alarm
                // bounds the fixture if termination regresses.
                arguments: ["-e", "$SIG{TERM} = 'IGNORE'; $| = 1; alarm 20; print \"$$\\n\"; sleep 30;"],
                onOutput: { await observation.record($0) }
            )
        }
        let stopRequested: ContinuousClock.Instant
        if cancel {
            // Cancel only once perl has proved it ignores TERM, never after a fixed sleep.
            let deadline = ContinuousClock.now + .seconds(15)
            while await observation.pid == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            stopRequested = .now
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            stopRequested = .now + timeout
            await #expect(throws: BoundedCommandError.timedOut) { try await task.value }
        }
        // Escalation to SIGKILL, not the fixture's alarm, ends the process.
        #expect(stopRequested.duration(to: .now) < .seconds(3))
        let pid = try #require(await observation.pid)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func normalExitPreservesStatusAndOutputLimit() async throws {
        let result = try await BoundedCommandRunner(maximumOutputBytes: 4).run(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print 'abcdefgh'; exit 7;"]
        )
        #expect(result.exitCode == 7)
        #expect(result.output == "efgh")
        #expect(result.outputWasTruncated)
        await #expect(throws: BoundedCommandError.unavailable) {
            try await BoundedCommandRunner().run(
                executableURL: URL(fileURLWithPath: "/nonexistent/Harness-command"), arguments: []
            )
        }
    }
}

private actor ProcessObservation {
    private var output = ""
    /// Only a complete line counts; a partial chunk such as "12" of "12345\n" is not a PID.
    var pid: Int32? {
        guard let line = output.split(separator: "\n", omittingEmptySubsequences: false).first,
              output.contains("\n") else { return nil }
        return Int32(line)
    }
    func record(_ value: String) { output += value }
}
