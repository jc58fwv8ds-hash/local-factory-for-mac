import Foundation
import HarnessExecution
import Testing
@testable import TaskOrchestrator

struct InferenceHealthReuseTests {
    func measurement(ageSeconds: Double, healthy: Bool?, model: String?, now: Date) -> InferenceHealth.Measurement {
        var m = InferenceHealth.Measurement(measuredAt: now.addingTimeInterval(-ageSeconds), firstTokenSeconds: 8,
            decodeChunksPerSecond: 37, chunks: 60, promptBytes: 3000, memoryPressureLevel: 1, swapUsedBytes: 0,
            onACPower: true, thermalState: "nominal", lowPowerMode: false)
        m.healthy = healthy; m.model = model
        return m
    }

    @Test func onlyARecentHealthyProbeOfTheSameModelIsReused() {
        let now = Date(), model = "openai:qwen3.8-27b-iq4xs"
        #expect(InferenceHealthGate.reusable(measurement(ageSeconds: 30, healthy: true, model: model, now: now), model: model, now: now) != nil)
        #expect(InferenceHealthGate.reusable(measurement(ageSeconds: 700, healthy: true, model: model, now: now), model: model, now: now) == nil)
        #expect(InferenceHealthGate.reusable(measurement(ageSeconds: 30, healthy: false, model: model, now: now), model: model, now: now) == nil)
        #expect(InferenceHealthGate.reusable(measurement(ageSeconds: 30, healthy: true, model: "other", now: now), model: model, now: now) == nil)
        #expect(InferenceHealthGate.reusable(measurement(ageSeconds: 30, healthy: true, model: nil, now: now), model: model, now: now) == nil)
        #expect(InferenceHealthGate.reusable(nil, model: model, now: now) == nil)
    }
}
