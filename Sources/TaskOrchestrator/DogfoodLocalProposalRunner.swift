import Foundation
import HarnessCore
import HarnessExecution
import HarnessKernel

/// The single local model-call point (supervised, budgeted, never retried) and its health handling.
package enum DogfoodLocalProposalRunner {
    package enum Failure: Error { case arguments, scope, timeout, unfinishedApply, environmentInvalid(String) }
    /// Generation budget from measured local throughput (2026-09-26, Qwen3.8-27B Q4_K_M on
    /// this Mac: ~126 prompt tok/s, ~5.7 output tok/s): 30 s load/overhead + prompt at
    /// ≈2 bytes/token / 100 tok/s + full output allowance at 5.5 tok/s; cap 480 s. Never retried.
    static func generationBudget(promptBytes: Int, outputTokens: Int = 2_048) -> Int {
        min(480, 30 + promptBytes / 200 + outputTokens * 10 / 55)
    }

    /// Context window large enough for the whole prompt plus output (≈2 bytes/token for
    /// mixed Japanese/code, +1K margin), in 4K steps, 8K…32K. Prompts are never truncated silently.
    static func contextWindow(promptBytes: Int, outputTokens: Int) -> Int {
        let needed = promptBytes / 2 + outputTokens + 1_024
        return min(32_768, max(8_192, (needed + 4_095) / 4_096 * 4_096))
    }

    /// Every model call of a run is counted (calls, bytes in/out, seconds) for the task-suite KPIs.
    package static func collect(_ original: InferenceRequest) async throws -> String {
        let bytes = original.messages.reduce(0) { $0 + $1.content.utf8.count }
        let started = InferenceEnvironment.continuousSeconds()
        do {
            let response = try await collectUncounted(original)
            InferenceEnvironment.shared.recordUsage(promptBytes: bytes, responseBytes: response.utf8.count,
                seconds: InferenceEnvironment.continuousSeconds() - started, failed: false)
            return response
        } catch {
            InferenceEnvironment.shared.recordUsage(promptBytes: bytes, responseBytes: 0,
                seconds: InferenceEnvironment.continuousSeconds() - started, failed: true)
            throw error
        }
    }

    private static func collectUncounted(_ original: InferenceRequest) async throws -> String {
        let bytes = original.messages.reduce(0) { $0 + $1.content.utf8.count }
        let route = InferenceRoute.resolve(original.modelIdentifier, default: original.runtime)
        let request = InferenceRequest(runtime: route.runtime, modelIdentifier: route.model,
            messages: original.messages, maximumOutputTokens: original.maximumOutputTokens,
            structuredOutput: original.structuredOutput, images: original.images,
            minimumContextTokens: contextWindow(promptBytes: bytes, outputTokens: original.maximumOutputTokens),
            temperature: InferenceRoute.temperature(original.modelIdentifier) ?? original.temperature)
        guard bytes / 2 + original.maximumOutputTokens <= 32_768 else { throw Failure.scope }
        if let script = PilotModelSeam.script { return try await script.respond(request) }
        let seconds = Double(generationBudget(promptBytes: bytes, outputTokens: original.maximumOutputTokens))
        // Inference Health watchdog: a stall, degraded generation or system sleep ends the
        // call as ENVIRONMENT_INVALID (recorded on the shared environment), never as a model failure.
        let environment = InferenceEnvironment.shared
        if let reason = environment.invalidation { throw Failure.environmentInvalid(reason) }
        let reference = environment.reference
        let progress = GenerationProgress()
        let awakeStart = InferenceEnvironment.awakeSeconds(), continuousStart = InferenceEnvironment.continuousSeconds()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var result = ""
                for try await part in await LocalInferenceService().events(for: request) {
                    try Task.checkCancellation()
                    progress.mark(InferenceEnvironment.awakeSeconds() - awakeStart)
                    result += part
                    // 16 KB for the default 2048-token calls; proportionally more for calls granted a larger output budget.
                    guard result.utf8.count <= max(16_000, original.maximumOutputTokens * 6) else { throw Failure.scope }
                }
                return result
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(5))
                    let awake = InferenceEnvironment.awakeSeconds() - awakeStart
                    let wall = InferenceEnvironment.continuousSeconds() - continuousStart
                    var reason: String?
                    if InferenceHealth.slept(continuousDelta: wall, awakeDelta: awake) {
                        reason = String(format: "systemSleep(%.0fs)", wall - awake)
                    } else if let stall = InferenceHealth.stall(progress.snapshot, now: awake, promptBytes: bytes, reference: reference) {
                        reason = stall
                    } else if awake >= seconds {
                        guard reference != nil, InferenceHealth.timeoutIsEnvironmental(progress.snapshot, elapsed: awake, reference: reference)
                        else { throw Failure.timeout }
                        reason = "generationBudgetExceededWhileDegraded"
                    }
                    if let reason { environment.invalidate(reason); throw Failure.environmentInvalid(reason) }
                }
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw Failure.timeout }
            return result
        }
    }
}

/// Streamed-chunk timing shared between the stream reader and the watchdog.
final class GenerationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = InferenceHealth.Progress()
    func mark(_ time: Double) {
        lock.withLock {
            if progress.firstTokenAt == nil { progress.firstTokenAt = time } else { progress.chunkTimes.append(time) }
            progress.lastChunkAt = time
        }
    }
    var snapshot: InferenceHealth.Progress { lock.withLock { progress } }
}
