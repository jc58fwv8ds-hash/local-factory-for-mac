import Foundation
import Testing
@testable import HarnessExecution

/// Synthetic checks of the Inference Health Gate policy: relative (never hard-coded)
/// thresholds, stall and sleep detection, and capability-vs-environment timeout split.
struct InferenceHealthTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func m(_ rate: Double, first: Double? = 20, chunks: Int = 64, pressure: Int = 1, thermal: String = "nominal",
           daysAgo: Double = 0, healthy: Bool? = nil) -> InferenceHealth.Measurement {
        .init(measuredAt: now.addingTimeInterval(-daysAgo * 86_400), firstTokenSeconds: first, decodeChunksPerSecond: rate,
              chunks: chunks, promptBytes: 3_000, memoryPressureLevel: pressure, swapUsedBytes: 0, onACPower: true,
              thermalState: thermal, lowPowerMode: false, healthy: healthy)
    }

    @Test func thresholdIsRelativeToTheReferenceNotAFixedRate() {
        for base in [2.0, 6.0, 40.0] {
            let reference = InferenceHealth.reference(baseline: m(base), history: [], now: now)
            #expect(reference?.source == "baseline")
            #expect(InferenceHealth.evaluate(m(base * 0.7), reference: reference).healthy)
            let slow = InferenceHealth.evaluate(m(base * 0.5), reference: reference)
            #expect(!slow.healthy && slow.reasons.first!.hasPrefix("decodeBelowReference"))
        }
    }

    @Test func referenceFallsBackToMostRecentHealthyMeasurement() {
        let history = [m(5, daysAgo: 3, healthy: true), m(0.5, daysAgo: 1, healthy: false), m(4, daysAgo: 2, healthy: true)]
        let stale = m(9, daysAgo: 30)
        let reference = InferenceHealth.reference(baseline: stale, history: history, now: now)
        #expect(reference?.source == "recentHealthy" && reference?.decodeChunksPerSecond == 4)
        #expect(InferenceHealth.reference(baseline: nil, history: [m(1, healthy: false)], now: now) == nil)
        #expect(InferenceHealth.evaluate(m(5), reference: nil).reasons == ["noHealthyReference"])
    }

    @Test func noGenerationMemoryAndThermalAreUnhealthy() {
        let reference = InferenceHealth.reference(baseline: m(5), history: [], now: now)
        #expect(InferenceHealth.evaluate(m(0, first: nil, chunks: 0), reference: reference).reasons == ["noGeneration"])
        #expect(InferenceHealth.evaluate(m(5, pressure: 4), reference: reference).reasons == ["memoryPressureCritical"])
        #expect(InferenceHealth.evaluate(m(5, thermal: "critical"), reference: reference).reasons == ["thermalCritical"])
        #expect(InferenceHealth.evaluate(m(5, pressure: 2), reference: reference).healthy)
    }

    @Test func baselineNeedsConsistentProbesUnderNormalPressure() {
        #expect(InferenceHealth.baseline(from: [m(5.8), m(5.6), m(6.0)])?.decodeChunksPerSecond == 5.8)
        #expect(InferenceHealth.baseline(from: [m(5.8), m(5.6)]) == nil)
        #expect(InferenceHealth.baseline(from: [m(5.8), m(1.0), m(6.0)]) == nil)
        #expect(InferenceHealth.baseline(from: [m(5.8), m(5.6), m(6.0, pressure: 4)]) == nil)
        #expect(InferenceHealth.baseline(from: [m(5.8), m(5.6), m(6.0, pressure: 2)]) != nil)
    }

    @Test func stallDetection() {
        let reference = InferenceHealth.Reference(decodeChunksPerSecond: 5, promptBytesPerSecond: 200, source: "baseline", measuredAt: now)
        var p = InferenceHealth.Progress()
        // Before the first token: deadline = 90 + bytes / (0.25 * 200).
        #expect(InferenceHealth.stall(p, now: 280, promptBytes: 10_000, reference: reference) == nil)
        #expect(InferenceHealth.stall(p, now: 291, promptBytes: 10_000, reference: reference)?.hasPrefix("noFirstToken") == true)
        #expect(InferenceHealth.stall(p, now: 10_000, promptBytes: 10_000, reference: nil) == nil)
        // Healthy decode: 5 chunks/s for 60 s.
        p.firstTokenAt = 10
        p.chunkTimes = stride(from: 10.2, through: 70, by: 0.2).map { $0 }
        p.lastChunkAt = 70
        #expect(InferenceHealth.stall(p, now: 70, promptBytes: 10_000, reference: reference) == nil)
        // Decode collapses to 0.5 chunks/s for a full window.
        p.chunkTimes += stride(from: 72, through: 130, by: 2).map { $0 }
        p.lastChunkAt = 130
        #expect(InferenceHealth.stall(p, now: 131, promptBytes: 10_000, reference: reference)?.hasPrefix("decodeStalled") == true)
        // Silence after the first token is a stall even without a reference.
        #expect(InferenceHealth.stall(p, now: 221, promptBytes: 10_000, reference: nil)?.hasPrefix("generationSilent") == true)
    }

    @Test func timeoutAtHealthyRateStaysACapabilityOutcome() {
        let reference = InferenceHealth.Reference(decodeChunksPerSecond: 5, promptBytesPerSecond: 200, source: "baseline", measuredAt: now)
        var healthy = InferenceHealth.Progress(); healthy.firstTokenAt = 30
        healthy.chunkTimes = Array(repeating: 1, count: 2_000)
        #expect(!InferenceHealth.timeoutIsEnvironmental(healthy, elapsed: 430, reference: reference))
        var degraded = InferenceHealth.Progress(); degraded.firstTokenAt = 30
        degraded.chunkTimes = Array(repeating: 1, count: 300)
        #expect(InferenceHealth.timeoutIsEnvironmental(degraded, elapsed: 430, reference: reference))
        #expect(InferenceHealth.timeoutIsEnvironmental(.init(), elapsed: 430, reference: reference))
    }

    @Test func sleepIsWallTimeTheAwakeClockDidNotSee() {
        #expect(!InferenceHealth.slept(continuousDelta: 100, awakeDelta: 98))
        #expect(InferenceHealth.slept(continuousDelta: 1_300, awakeDelta: 100))
    }

    @Test func japaneseOutputCountsByAmountNotByPieces() {
        #expect(InferenceHealth.decodeUnits("") == 1)
        #expect(InferenceHealth.decodeUnits(" the") == 1)
        // 合計がちょうど5000円 (one larger piece of Japanese): about one unit per token, not one per piece.
        #expect(InferenceHealth.decodeUnits("合計がちょうど5000円") == 9)
        #expect(InferenceHealth.decodeUnits(#"{"requirement": "x"}"#) == 5)
    }
}
