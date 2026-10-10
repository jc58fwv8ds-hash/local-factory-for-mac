import Foundation
import HarnessCore
@testable import HarnessExecution
import Testing

struct ValidationExecutionLeaseTests {
    @Test func anotherProcessCannotAcquireAHeldLeaseAndCanAcquireAfterRelease() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("probe.lock")
        var lease: LocalExecutionLease? = try LocalExecutionLease(file: file)
        #expect(try await probe(file) == 3)
        withExtendedLifetime(lease) {}
        lease = nil
        #expect(try await probe(file) == 0)
    }

    @Test(arguments: [false, true])
    func competingServiceCannotRunOrReplaceIndex(cancel: Bool) async throws {
        let fixture = try LeaseFixture()
        defer { fixture.remove() }
        let provider = GatedValidation()
        let first = fixture.service(provider)
        let secondProvider = ImmediateValidation()
        let second = fixture.service(secondProvider)
        let running = Task { try await first.validate(rootPath: fixture.source.path) }
        await provider.waitUntilStarted()
        defer { running.cancel(); Task { await provider.finish() } }
        let index = RootRunIndex(directory: fixture.runs)
        let initialID = try #require(try index.load(root: fixture.source))
        await #expect(throws: (any Error).self) { try await second.validate(rootPath: fixture.source.path) }
        #expect(await secondProvider.calls == 0)
        #expect(try index.load(root: fixture.source) == initialID)
        #expect(try await second.recoverValidation(rootPath: fixture.source.path) == .unresolved)
        // A different project sharing the output directory may still proceed.
        #expect(try await second.validate(rootPath: fixture.otherSource.path).succeeded)
        if cancel { running.cancel() }
        await provider.finish()
        if cancel {
            await #expect(throws: CancellationError.self) { try await running.value }
            #expect(try await second.recoverValidation(rootPath: fixture.source.path) == .unresolved)
        } else {
            #expect(try await running.value.succeeded)
            #expect(try await second.recoverValidation(rootPath: fixture.source.path) == .verified)
        }
        // Explicit validation after the original operation exits can obtain the lease.
        #expect(try await second.validate(rootPath: fixture.source.path).succeeded)
        #expect(try index.load(root: fixture.source) != initialID)
    }

    private func probe(_ file: URL) async throws -> Int32 {
        let result = try await BoundedCommandRunner(timeout: .seconds(5)).run(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-MFcntl=:flock", "-e",
                        "open(my $f, '+<', $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 3);", file.path]
        )
        return result.exitCode
    }
}

private struct LeaseFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessLease-\(UUID())")
        .standardizedFileURL.resolvingSymlinksInPath()
    var source: URL { root.appendingPathComponent("source") }
    var otherSource: URL { root.appendingPathComponent("other") }
    var runs: URL { root.appendingPathComponent("runs") }
    init() throws {
        for path in [source, otherSource] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("let value = 1".utf8).write(to: path.appendingPathComponent("Example.swift"))
        }
    }
    func service(_ provider: any ProjectValidating) -> RecordedProjectValidationService {
        .init(provider: provider, directory: runs, requireTests: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func successReport() -> ProjectValidationReport {
    .init(startedAt: .now, finishedAt: .now, checks: [.build, .test].map {
        ProjectValidationCheck(kind: $0, succeeded: true, exitCode: 0,
            output: $0 == .build ? "Build succeeded" : "Executed 1 test", outputWasTruncated: false, duration: 0)
    })
}

private actor ImmediateValidation: ProjectValidating {
    var calls = 0
    func support(rootPath: String) async -> ProjectValidationSupport? { .init(system: .swiftPackage) }
    func validate(rootPath: String) async throws -> ProjectValidationReport { calls += 1; return successReport() }
}

private actor GatedValidation: ProjectValidating {
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func support(rootPath: String) async -> ProjectValidationSupport? { .init(system: .swiftPackage) }
    func validate(rootPath: String) async throws -> ProjectValidationReport {
        await withCheckedContinuation {
            pending = $0
            waiter?.resume()
            waiter = nil
        }
        try Task.checkCancellation()
        return successReport()
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { pending?.resume(); pending = nil }
}
