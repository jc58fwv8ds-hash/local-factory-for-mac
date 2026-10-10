import Foundation
import HarnessCore
import HarnessExecution

/// Deterministic test seam for the batch pipeline. Production never binds `script`, so every model
/// call and health probe goes to the live runtime. Inside a test, a task-local script answers the
/// model calls and the health gate reports a synthetic healthy probe without touching the shared
/// health store. Being task-local, a script cannot leak into another task or into a CLI run.
package enum PilotModelSeam {
    package struct Script: Sendable {
        let respond: @Sendable (InferenceRequest) async throws -> String
        package init(respond: @escaping @Sendable (InferenceRequest) async throws -> String) { self.respond = respond }
    }
    @TaskLocal package static var script: Script?

    static func syntheticHealth(context: String) -> (InferenceHealth.Measurement, InferenceHealth.Verdict) {
        var measurement = InferenceHealth.Measurement(measuredAt: Date(), firstTokenSeconds: 0.1, decodeChunksPerSecond: 10,
            chunks: 60, promptBytes: 0, memoryPressureLevel: 1, swapUsedBytes: 0, onACPower: true,
            thermalState: "nominal", lowPowerMode: false)
        let verdict = InferenceHealth.evaluate(measurement,
            reference: InferenceHealth.reference(baseline: measurement, history: [], now: Date()))
        measurement.healthy = verdict.healthy
        measurement.context = context + ":scripted"
        return (measurement, verdict)
    }
}
