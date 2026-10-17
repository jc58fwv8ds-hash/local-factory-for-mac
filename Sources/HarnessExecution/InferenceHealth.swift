import Foundation

/// Inference Health Gate policy. Health is always judged relative to a known healthy
/// baseline (or, without one, the most recent healthy measurement) measured by the same
/// method on this machine — never against a hard-coded throughput. An unhealthy
/// environment makes a run ENVIRONMENT_INVALID: excluded from capability rates and
/// recorded as an operational-reliability event instead.
public enum InferenceHealth {
    /// Pre-task probe must reach this fraction of the reference decode rate.
    public static let healthyRatio = 0.6
    /// In-task generation below this fraction of the reference is a stall.
    public static let stallRatio = 0.25
    /// No streamed output for this long after the first token is a stall.
    public static let silenceLimitSeconds = 90.0
    /// Window over which in-task decode progress is measured.
    public static let progressWindowSeconds = 60.0
    /// Wall-clock time the machine spent asleep beyond which a run is invalid.
    public static let sleepToleranceSeconds = 5.0
    public static let baselineMaximumAgeDays = 14.0

    public struct Measurement: Codable, Sendable, Equatable {
        public let measuredAt: Date
        public let firstTokenSeconds: Double?
        public let decodeChunksPerSecond: Double
        public let chunks: Int
        public let promptBytes: Int
        public let memoryPressureLevel: Int
        public let swapUsedBytes: UInt64
        public let onACPower: Bool?
        public let thermalState: String
        public let lowPowerMode: Bool
        public var healthy: Bool?
        public var context: String?
        /// Model the probe ran against (recorded since 2026-10-07; older lines have none and are never reused).
        public var model: String?
        public init(measuredAt: Date, firstTokenSeconds: Double?, decodeChunksPerSecond: Double, chunks: Int,
                    promptBytes: Int, memoryPressureLevel: Int, swapUsedBytes: UInt64, onACPower: Bool?,
                    thermalState: String, lowPowerMode: Bool, healthy: Bool? = nil) {
            self.measuredAt = measuredAt; self.firstTokenSeconds = firstTokenSeconds
            self.decodeChunksPerSecond = decodeChunksPerSecond; self.chunks = chunks; self.promptBytes = promptBytes
            self.memoryPressureLevel = memoryPressureLevel; self.swapUsedBytes = swapUsedBytes
            self.onACPower = onACPower; self.thermalState = thermalState; self.lowPowerMode = lowPowerMode
            self.healthy = healthy
        }
        /// Conservative prompt throughput: first-token latency includes load and overhead.
        public var promptBytesPerSecond: Double {
            guard let first = firstTokenSeconds, first > 0 else { return 0 }
            return Double(promptBytes) / first
        }
    }

    public struct Reference: Codable, Sendable, Equatable {
        public let decodeChunksPerSecond: Double
        public let promptBytesPerSecond: Double
        public let source: String
        public let measuredAt: Date
    }

    public struct Verdict: Codable, Sendable, Equatable {
        public let healthy: Bool
        public let reasons: [String]
        public let reference: Reference?
    }

    /// The known healthy baseline while it is fresh; otherwise the most recent measurement
    /// that was itself judged healthy. Never a hard-coded rate.
    public static func reference(baseline: Measurement?, history: [Measurement], now: Date) -> Reference? {
        if let baseline, now.timeIntervalSince(baseline.measuredAt) <= baselineMaximumAgeDays * 86_400 {
            return .init(decodeChunksPerSecond: baseline.decodeChunksPerSecond,
                         promptBytesPerSecond: baseline.promptBytesPerSecond, source: "baseline", measuredAt: baseline.measuredAt)
        }
        guard let recent = history.filter({ $0.healthy == true }).max(by: { $0.measuredAt < $1.measuredAt }) else { return nil }
        return .init(decodeChunksPerSecond: recent.decodeChunksPerSecond,
                     promptBytesPerSecond: recent.promptBytesPerSecond, source: "recentHealthy", measuredAt: recent.measuredAt)
    }

    public static func evaluate(_ m: Measurement, reference: Reference?) -> Verdict {
        var reasons: [String] = []
        if m.chunks == 0 { reasons.append("noGeneration") }
        if let reference {
            if m.chunks > 0, m.decodeChunksPerSecond < healthyRatio * reference.decodeChunksPerSecond {
                reasons.append(String(format: "decodeBelowReference(%.2f < %.0f%% of %.2f)", m.decodeChunksPerSecond,
                                      healthyRatio * 100, reference.decodeChunksPerSecond))
            }
        } else { reasons.append("noHealthyReference") }
        if m.memoryPressureLevel >= 4 { reasons.append("memoryPressureCritical") }
        if m.thermalState == "critical" { reasons.append("thermalCritical") }
        return .init(healthy: reasons.isEmpty, reasons: reasons, reference: reference)
    }

    /// A baseline needs several consistent probes without critical memory pressure.
    public static func baseline(from probes: [Measurement]) -> Measurement? {
        guard probes.count >= 3, probes.allSatisfy({ $0.chunks > 0 && $0.memoryPressureLevel < 4 && $0.firstTokenSeconds != nil })
        else { return nil }
        let rates = probes.map(\.decodeChunksPerSecond).sorted()
        guard let low = rates.first, let high = rates.last, high > 0, low / high >= 0.8 else { return nil }
        let median = probes.sorted { $0.decodeChunksPerSecond < $1.decodeChunksPerSecond }[probes.count / 2]
        var chosen = median; chosen.healthy = true
        return chosen
    }

    // MARK: In-task watchdog

    /// How many decode units a streamed piece counts for: about one per token (4 bytes of UTF-8), at least one per piece.
    /// Counting pieces alone misjudged Japanese and grammar-constrained output, which arrives in fewer, larger pieces:
    /// on 2026-10-11/12 plans with Japanese examples (#40) were cut off as decodeStalled at 6 pieces/s while the server
    /// generated 15 tokens/s (1 → 1 → 2 of 22 C2 runs).
    /// A character outside ASCII (Japanese) is about one token by itself, so it counts as one unit; ASCII text counts one
    /// unit per 4 bytes (2026-10-12: with 4 bytes for everything, a Japanese plan at 15 tokens/s still read as 9.3 units/s
    /// against a reference of 40 and was cut off once more).
    public static func decodeUnits(_ piece: String) -> Int {
        let ascii = piece.unicodeScalars.filter(\.isASCII).count
        return max(1, (ascii + 3) / 4 + piece.unicodeScalars.count - ascii)
    }

    public struct Progress: Sendable, Equatable {
        public var firstTokenAt: Double?
        public var lastChunkAt: Double?
        /// Awake-clock timestamps of streamed chunks (seconds since the request started).
        public var chunkTimes: [Double] = []
        public init() {}
    }

    /// Time allowed before the first token: fixed overhead plus the prompt at the stall
    /// fraction of the reference prompt throughput. Without a reference, no deadline.
    public static func firstTokenDeadline(promptBytes: Int, reference: Reference?) -> Double? {
        guard let reference, reference.promptBytesPerSecond > 0 else { return nil }
        return 90 + Double(promptBytes) / (stallRatio * reference.promptBytesPerSecond)
    }

    /// Returns why the generation counts as stalled at `now` (awake seconds since start), or nil.
    public static func stall(_ p: Progress, now: Double, promptBytes: Int, reference: Reference?) -> String? {
        guard let first = p.firstTokenAt else {
            if let deadline = firstTokenDeadline(promptBytes: promptBytes, reference: reference), now > deadline {
                return String(format: "noFirstToken(%.0fs > %.0fs)", now, deadline)
            }
            return nil
        }
        if let last = p.lastChunkAt, now - last > silenceLimitSeconds {
            return String(format: "generationSilent(%.0fs)", now - last)
        }
        guard let reference, now - first >= progressWindowSeconds else { return nil }
        let recent = p.chunkTimes.filter { $0 > now - progressWindowSeconds }.count
        let rate = Double(recent) / progressWindowSeconds
        if rate < stallRatio * reference.decodeChunksPerSecond {
            return String(format: "decodeStalled(%.2f < %.0f%% of %.2f)", rate, stallRatio * 100, reference.decodeChunksPerSecond)
        }
        return nil
    }

    /// At the generation budget: a timeout while generating at a degraded rate is an
    /// environment failure; a timeout at a healthy rate stays a model/capability outcome.
    public static func timeoutIsEnvironmental(_ p: Progress, elapsed: Double, reference: Reference?) -> Bool {
        guard let first = p.firstTokenAt else { return true }
        guard let reference else { return false }
        let rate = Double(p.chunkTimes.count) / max(elapsed - first, 1)
        return rate < healthyRatio * reference.decodeChunksPerSecond
    }

    /// Sleep detection: wall (continuous) time that passed while the awake clock did not.
    public static func slept(continuousDelta: Double, awakeDelta: Double) -> Bool {
        continuousDelta - awakeDelta > sleepToleranceSeconds
    }
}
