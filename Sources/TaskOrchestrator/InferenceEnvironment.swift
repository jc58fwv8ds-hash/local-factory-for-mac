import Darwin
import Foundation
import HarnessCore
import HarnessExecution
import IOKit.ps

/// Process-wide inference environment state for one batch run: the health reference, the
/// run's clocks and any ENVIRONMENT_INVALID event. Stages may wrap errors, so the runner
/// reads the invalidation from here instead of relying on an error type.
package final class InferenceEnvironment: @unchecked Sendable {
    package static let shared = InferenceEnvironment()
    private let lock = NSLock()
    private var storedReference: InferenceHealth.Reference?
    private var storedInvalidation: String?
    private var storedEvents: [String] = []
    private var storedUsage: [String: Double] = [:]
    private var runStart = (continuous: InferenceEnvironment.continuousSeconds(), awake: InferenceEnvironment.awakeSeconds())

    var reference: InferenceHealth.Reference? { lock.withLock { storedReference } }
    var invalidation: String? { lock.withLock { storedInvalidation } }
    package var events: [String] { lock.withLock { storedEvents } }

    func begin(reference: InferenceHealth.Reference?) {
        lock.withLock {
            storedReference = reference; storedInvalidation = nil; storedEvents = []; storedUsage = [:]
            runStart = (Self.continuousSeconds(), Self.awakeSeconds())
        }
    }
    func invalidate(_ reason: String) {
        lock.withLock {
            storedEvents.append(reason)
            if storedInvalidation == nil { storedInvalidation = reason }
        }
    }
    func note(_ event: String) { lock.withLock { storedEvents.append(event) } }
    /// Model-call usage since `begin`: calls, failedCalls, promptBytes, responseBytes, seconds.
    package var usage: [String: Double] { lock.withLock { storedUsage } }
    func recordUsage(promptBytes: Int, responseBytes: Int, seconds: Double, failed: Bool) {
        lock.withLock {
            for (key, value) in ["calls": 1, "failedCalls": failed ? 1 : 0, "promptBytes": Double(promptBytes),
                                 "responseBytes": Double(responseBytes), "seconds": seconds] {
                storedUsage[key, default: 0] += value
            }
        }
    }
    /// Seconds the machine slept since the run began.
    package var sleptSeconds: Double {
        lock.withLock { max(0, (Self.continuousSeconds() - runStart.continuous) - (Self.awakeSeconds() - runStart.awake)) }
    }

    /// Advances during sleep.
    static func continuousSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }
    /// Stops during sleep.
    static func awakeSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    struct System { let memoryPressureLevel: Int; let swapUsedBytes: UInt64; let onACPower: Bool?; let thermal: String; let lowPower: Bool }

    static func system() -> System {
        var level: Int32 = 0, size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) != 0 { level = 0 }
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 { swap = xsw_usage() }
        var ac: Bool?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            ac = type == kIOPMACPowerKey
        }
        let thermal: String = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return .init(memoryPressureLevel: Int(level), swapUsedBytes: swap.xsu_used, onACPower: ac,
                     thermal: thermal, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// Small local inference probe and the pre-task gate built on it.
package enum InferenceHealthGate {
    /// Mixed Japanese / Swift filler, close to task prompts in bytes per token.
    static let probeFiller = String(repeating: "設定の値を確認して、結果を短く返してください。 let limit = values.filter { $0 > 12 }.count\n", count: 30)

    static var store: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/Dogfood/inference-health")
    }

    /// One bounded probe: ~3 KB prompt, 64 output tokens, streamed; decode rate is measured
    /// between streamed chunks, the same way the in-task watchdog measures progress.
    static func probe(model: String) async -> InferenceHealth.Measurement {
        // A unique first line defeats the runtime's prompt cache, so prompt time is really measured.
        let prompt = "probe \(UUID().uuidString)\n" + probeFiller + "\nIgnore the text above. Count from 1 to 60 separated by single spaces."
        let route = InferenceRoute.resolve(model, default: .ollama)
        let request = InferenceRequest(runtime: route.runtime, modelIdentifier: route.model,
            messages: [.init(role: .user, content: prompt)], maximumOutputTokens: 64)
        let start = InferenceEnvironment.awakeSeconds()
        let (first, last, chunks) = await withTaskGroup(of: (Double?, Double, Int)?.self) { group in
            group.addTask {
                var first: Double?, last = start, chunks = 0
                do {
                    for try await _ in await LocalInferenceService().events(for: request) {
                        let now = InferenceEnvironment.awakeSeconds()
                        if first == nil { first = now } else { chunks += 1 }
                        last = now
                    }
                } catch {}
                return (first, last, chunks)
            }
            group.addTask { try? await Task.sleep(for: .seconds(180)); return nil }
            let outcome = await group.next() ?? nil
            group.cancelAll()
            return outcome ?? (nil, start, 0)
        }
        let system = InferenceEnvironment.system()
        let rate = first.map { chunks > 0 ? Double(chunks) / max(last - $0, 0.001) : 0 } ?? 0
        return .init(measuredAt: Date(), firstTokenSeconds: first.map { $0 - start }, decodeChunksPerSecond: rate,
                     chunks: first == nil ? 0 : chunks + 1, promptBytes: prompt.utf8.count,
                     memoryPressureLevel: system.memoryPressureLevel, swapUsedBytes: system.swapUsedBytes,
                     onACPower: system.onACPower, thermalState: system.thermal, lowPowerMode: system.lowPower)
    }

    static func history() -> [InferenceHealth.Measurement] {
        guard let text = try? String(contentsOf: store.appendingPathComponent("probes.jsonl"), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(InferenceHealth.Measurement.self, from: Data($0.utf8)) }
    }

    static func baseline() -> InferenceHealth.Measurement? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: store.appendingPathComponent("baseline.json")))
            .flatMap { try? decoder.decode(InferenceHealth.Measurement.self, from: $0) }
    }

    static func append(_ measurement: InferenceHealth.Measurement, context: String) throws {
        var m = measurement; m.context = context
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(m); line.append(0x0A)
        let url = store.appendingPathComponent("probes.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line)
    }

    /// Probe, judge against the reference, persist the measurement with its verdict.
    package static func check(model: String, context: String) async throws -> (InferenceHealth.Measurement, InferenceHealth.Verdict) {
        if PilotModelSeam.script != nil { return PilotModelSeam.syntheticHealth(context: context) }
        let reference = InferenceHealth.reference(baseline: baseline(), history: history(), now: Date())
        // A pre-task check right after a healthy probe of the same model (normally the previous task's post-task check,
        // seconds earlier) reuses it instead of another ~15 s uncached probe: 565 of 565 recorded probes were healthy, and the
        // in-task watchdog still guards every call. The post-task check always probes.
        if context.hasSuffix(":preTask"), let recent = reusable(history().last, model: model, now: Date()) {
            var reused = recent
            let verdict = InferenceHealth.evaluate(reused, reference: reference)
            if verdict.healthy {
                reused.healthy = true
                try append(reused, context: context + "(reused)")
                return (reused, verdict)
            }
        }
        var measurement = await probe(model: model)
        measurement.model = model
        let verdict = InferenceHealth.evaluate(measurement, reference: reference)
        measurement.healthy = verdict.healthy
        try append(measurement, context: context)
        return (measurement, verdict)
    }

    static let reuseWindowSeconds: TimeInterval = 600

    /// The last measurement, if it is healthy, of the same model and younger than `reuseWindowSeconds`.
    static func reusable(_ last: InferenceHealth.Measurement?, model: String, now: Date) -> InferenceHealth.Measurement? {
        guard let last, last.healthy == true, last.model == model,
              now.timeIntervalSince(last.measuredAt) < reuseWindowSeconds else { return nil }
        return last
    }

    /// `--inference-health-baseline <model>`: operator-run on a known-healthy machine.
    package static func establishBaseline(arguments: [String]) async throws {
        guard arguments.count == 3 else { throw TaskOrchestrator.Failure.scope }
        var probes: [InferenceHealth.Measurement] = []
        for _ in 0..<3 { probes.append(await probe(model: arguments[2])) }
        guard let chosen = InferenceHealth.baseline(from: probes) else {
            print("Baseline not established (probes inconsistent or memory pressure elevated): "
                + probes.map { String(format: "%.2f", $0.decodeChunksPerSecond) }.joined(separator: ", "))
            throw TaskOrchestrator.Failure.scope
        }
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(chosen).write(to: store.appendingPathComponent("baseline.json"), options: .atomic)
        for probe in probes { var p = probe; p.healthy = true; try append(p, context: "baseline") }
        print(String(format: "Inference health baseline: %.2f chunks/s decode, first token %.1fs (%d probes).",
                     chosen.decodeChunksPerSecond, chosen.firstTokenSeconds ?? 0, probes.count))
    }
}
