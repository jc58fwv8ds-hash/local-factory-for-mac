import Foundation
import Testing
import HarnessCore

/// Fake servers for the coordinator: they take random time to start and stop, can fail to start, and report every
/// violation of the two rules (one model in memory at a time; a model in use is never stopped) to a shared monitor.
private actor Monitor {
    var running: [String: String?] = [:]
    var inUse: [String: Int] = [:]
    var violations: [String] = []
    var starts = 0

    func started(_ name: String, _ model: String?) {
        starts += 1
        if let other = running.keys.first(where: { $0 != name }) { violations.append("\(name) started while \(other) runs") }
        running[name] = model
    }
    func stopped(_ name: String) {
        if (inUse[name] ?? 0) > 0 { violations.append("\(name) stopped while in use") }
        running[name] = nil
    }
    func use(_ name: String, _ model: String?) {
        guard running.keys.contains(name), running[name] == model else { violations.append("\(name):\(model ?? "-") used but not running"); return }
        inUse[name, default: 0] += 1
    }
    func done(_ name: String) { inUse[name, default: 0] -= 1 }
}

private struct FakeBackend: ModelRuntimeBackend {
    let name: String
    let monitor: Monitor
    var failEvery = 0

    func start(model: String?) async throws {
        try await Task.sleep(for: .microseconds(Int.random(in: 0...300)))
        if failEvery > 0, Int.random(in: 0..<failEvery) == 0 { throw CancellationError() }
        await monitor.started(name, model)
    }
    func stop() async {
        try? await Task.sleep(for: .microseconds(Int.random(in: 0...200)))
        await monitor.stopped(name)
    }
}

struct ModelRuntimeCoordinatorTests {
    let big = ModelRuntimeCoordinator.Target(backend: "strata", model: "125b")
    let small = ModelRuntimeCoordinator.Target(backend: "backburner")

    @Test func aModelInUseIsNotStoppedByARequestForAnother() async throws {
        let monitor = Monitor()
        let coordinator = ModelRuntimeCoordinator(backends: ["strata": FakeBackend(name: "strata", monitor: monitor),
                                                            "backburner": FakeBackend(name: "backburner", monitor: monitor)])
        let lease = try await coordinator.acquire(big)
        await monitor.use("strata", "125b")
        let waiting = Task { try await coordinator.acquire(small) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await monitor.running.keys.contains("strata"))      // the 27B request waits; the 125B keeps writing
        await monitor.done("strata")
        await coordinator.release(lease)
        let next = try await waiting.value
        #expect(next.target == small && next.generation > lease.generation)
        #expect(await monitor.violations.isEmpty)
    }

    @Test func requestsAreServedInArrivalOrderSoAnotherModelIsNotStarved() async throws {
        let monitor = Monitor()
        let coordinator = ModelRuntimeCoordinator(backends: ["strata": FakeBackend(name: "strata", monitor: monitor),
                                                            "backburner": FakeBackend(name: "backburner", monitor: monitor)])
        let first = try await coordinator.acquire(small)
        let other = Task { try await coordinator.acquire(big) }
        try await Task.sleep(for: .milliseconds(10))
        let late = Task { try await coordinator.acquire(small) }   // arrives after the 125B request: must not jump the queue
        try await Task.sleep(for: .milliseconds(10))
        await coordinator.release(first)
        let bigLease = try await other.value
        let now = await coordinator.current
        #expect(now == big)
        await coordinator.release(bigLease)
        #expect(try await late.value.target == small)
    }

    @Test func cancellingAWaitingRequestLeavesNoLeaseBehind() async throws {
        let monitor = Monitor()
        let coordinator = ModelRuntimeCoordinator(backends: ["strata": FakeBackend(name: "strata", monitor: monitor),
                                                            "backburner": FakeBackend(name: "backburner", monitor: monitor)])
        let lease = try await coordinator.acquire(small)
        let waiting = Task { try await coordinator.acquire(big) }
        try await Task.sleep(for: .milliseconds(10))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await coordinator.release(lease)
        let (count, now) = (await coordinator.activeLeases, await coordinator.current)
        #expect(count == 0 && now == small)
    }

    @Test func aFailedStartIsReportedToItsWaitersAndTheNextRequestStillRuns() async throws {
        struct Broken: ModelRuntimeBackend {
            func start(model: String?) async throws { throw ModelRuntimeCoordinator.CoordinatorError.unknownBackend("broken") }
            func stop() async {}
        }
        let monitor = Monitor()
        let coordinator = ModelRuntimeCoordinator(backends: ["strata": Broken(),
                                                            "backburner": FakeBackend(name: "backburner", monitor: monitor)])
        await #expect(throws: ModelRuntimeCoordinator.CoordinatorError.self) { try await coordinator.acquire(big) }
        let lease = try await coordinator.acquire(small)
        let now = await coordinator.current
        #expect(lease.target == small && now == small)
    }

    /// Many requests for random models (and "no model", as the image model asks), with random timing, cancellations and
    /// failed starts: no moment may have two models running, and no model may stop while a request uses it.
    @Test func randomInterleavingsNeverBreakTheRules() async throws {
        for round in 0..<30 {
            let monitor = Monitor()
            let coordinator = ModelRuntimeCoordinator(backends: [
                "strata": FakeBackend(name: "strata", monitor: monitor, failEvery: 7),
                "backburner": FakeBackend(name: "backburner", monitor: monitor)])
            let targets = [big, small, .init(backend: "backburner", model: "fine-tune"), .none]
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<40 {
                    let target = targets[(i * 7 + round) % targets.count]
                    group.addTask {
                        let task = Task {
                            guard let lease = try? await coordinator.acquire(target) else { return }
                            if let name = target.backend { await monitor.use(name, target.model) }
                            try? await Task.sleep(for: .microseconds(Int.random(in: 0...400)))
                            if let name = target.backend { await monitor.done(name) }
                            await coordinator.release(lease)
                        }
                        if Int.random(in: 0..<6) == 0 { try? await Task.sleep(for: .microseconds(Int.random(in: 0...300))); task.cancel() }
                        await task.value
                    }
                }
                try await group.waitForAll()
            }
            #expect(await monitor.violations == [], "round \(round)")
            #expect(await coordinator.activeLeases == 0, "round \(round)")
        }
    }
}
