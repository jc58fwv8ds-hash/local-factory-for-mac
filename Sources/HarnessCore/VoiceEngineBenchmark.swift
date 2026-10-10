import Foundation

public struct VoiceEngineBenchmarkMeasurement: Codable, Equatable, Sendable {
    public let sequence: Int
    public let elapsedMilliseconds: Int
    public let audioDurationMilliseconds: Int
    public let sampleRate: Double
    public let audioByteCount: Int

    public init(
        sequence: Int,
        elapsedMilliseconds: Int,
        audioDurationMilliseconds: Int,
        sampleRate: Double,
        audioByteCount: Int
    ) {
        self.sequence = sequence
        self.elapsedMilliseconds = elapsedMilliseconds
        self.audioDurationMilliseconds = audioDurationMilliseconds
        self.sampleRate = sampleRate
        self.audioByteCount = audioByteCount
    }

    /// Conventional TTS real-time factor: lower than 1 means generation finished
    /// faster than the generated audio would take to play.
    public var realTimeFactor: Double {
        guard audioDurationMilliseconds > 0 else { return .infinity }
        return Double(elapsedMilliseconds) / Double(audioDurationMilliseconds)
    }
}

public enum VoiceEngineBenchmarkAssessment: String, Codable, Equatable, Sendable {
    case conversationCandidate
    case usableWithPause
    case previewOnly
}

public struct VoiceEngineBenchmarkReport: Codable, Equatable, Sendable {
    public let engineIdentifier: String
    public let measurements: [VoiceEngineBenchmarkMeasurement]
    public let assessment: VoiceEngineBenchmarkAssessment

    public init(
        engineIdentifier: String,
        measurements: [VoiceEngineBenchmarkMeasurement],
        assessment: VoiceEngineBenchmarkAssessment
    ) {
        self.engineIdentifier = engineIdentifier
        self.measurements = measurements
        self.assessment = assessment
    }

    public var initialMeasurement: VoiceEngineBenchmarkMeasurement? {
        measurements.first(where: { $0.sequence == 1 })
    }

    public var repeatedMeasurement: VoiceEngineBenchmarkMeasurement? {
        measurements.first(where: { $0.sequence == 2 })
    }
}

public enum VoiceEngineBenchmarkPolicy {
    public static let requiredMeasurementCount = 2

    // These are Harness product budgets for a non-streaming, full-clip path.
    // They are deliberately not presented as Qwen's streamed server benchmark.
    public static let conversationElapsedLimitMilliseconds = 2_500
    public static let conversationRealTimeFactorLimit = 0.75
    public static let pausedUseElapsedLimitMilliseconds = 10_000
    public static let pausedUseRealTimeFactorLimit = 1.5

    public static func report(
        engineIdentifier: String,
        measurements: [VoiceEngineBenchmarkMeasurement]
    ) -> VoiceEngineBenchmarkReport? {
        let ordered = measurements.sorted { $0.sequence < $1.sequence }
        guard isValid(engineIdentifier: engineIdentifier, measurements: ordered),
              let repeated = ordered.last else {
            return nil
        }
        let assessment: VoiceEngineBenchmarkAssessment
        if repeated.elapsedMilliseconds <= conversationElapsedLimitMilliseconds,
           repeated.realTimeFactor <= conversationRealTimeFactorLimit {
            assessment = .conversationCandidate
        } else if repeated.elapsedMilliseconds <= pausedUseElapsedLimitMilliseconds,
                  repeated.realTimeFactor <= pausedUseRealTimeFactorLimit {
            assessment = .usableWithPause
        } else {
            assessment = .previewOnly
        }
        return VoiceEngineBenchmarkReport(
            engineIdentifier: engineIdentifier,
            measurements: ordered,
            assessment: assessment
        )
    }

    private static func isValid(
        engineIdentifier: String,
        measurements: [VoiceEngineBenchmarkMeasurement]
    ) -> Bool {
        let identifier = engineIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.count <= 120,
              measurements.count == requiredMeasurementCount,
              measurements.map(\.sequence) == Array(1...requiredMeasurementCount) else {
            return false
        }
        return measurements.allSatisfy {
            $0.elapsedMilliseconds > 0 && $0.elapsedMilliseconds <= 180_000
                && $0.audioDurationMilliseconds > 0
                && $0.audioDurationMilliseconds <= 300_000
                && $0.sampleRate >= 8_000 && $0.sampleRate <= 96_000
                && $0.audioByteCount > 44 && $0.audioByteCount <= 100_000_000
                && $0.realTimeFactor.isFinite
        }
    }
}
