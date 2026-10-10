import Foundation

/// Transport-observed durations, not model compute time, tokens, or an estimate of remaining work.
public struct InferenceResponseTiming: Equatable, Sendable, Encodable {
    public let promptCharacters: Int
    public let promptComposition: InferencePromptComposition
    public let firstContentSeconds: Double?
    public let totalSeconds: Double

    public var receivingSeconds: Double? {
        firstContentSeconds.map { max(0, totalSeconds - $0) }
    }
}

/// A monotonic, content-free timer shared by the app and opt-in evaluations.
public struct InferenceResponseTimer: Sendable {
    private let startedAt: ContinuousClock.Instant
    private let promptComposition: InferencePromptComposition
    private var firstContentAt: ContinuousClock.Instant?

    public init(request: InferenceRequest, at instant: ContinuousClock.Instant = .now) {
        startedAt = instant
        promptComposition = InferencePromptComposition(
            messages: request.messages,
            images: request.images
        )
    }

    public mutating func observe(hasVisibleContent: Bool, at instant: ContinuousClock.Instant = .now) {
        if hasVisibleContent, firstContentAt == nil { firstContentAt = instant }
    }

    public func measurement(at instant: ContinuousClock.Instant = .now) -> InferenceResponseTiming {
        let total = seconds(until: instant)
        return InferenceResponseTiming(
            promptCharacters: promptComposition.totalCharacters,
            promptComposition: promptComposition,
            firstContentSeconds: firstContentAt.map { min(total, seconds(until: $0)) },
            totalSeconds: total
        )
    }

    private func seconds(until instant: ContinuousClock.Instant) -> Double {
        let duration = startedAt.duration(to: instant).components
        return max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }
}
