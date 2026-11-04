import Foundation

/// Where a model call is spending its time (2026-11-05, the user: show where it is stuck). One call passes through these in
/// order; a stage that took no time is left out of the summary.
public struct InferenceStages: Sendable, Equatable {
    public enum Stage: String, Sendable, CaseIterable {
        case waiting = "順番待ち", loading = "読み込み", reading = "入力", writing = "出力", media = "生成"
    }

    public private(set) var finished: [(stage: Stage, seconds: Double)] = []
    public private(set) var current: Stage?
    public private(set) var currentStarted: Date?
    public private(set) var pieces = 0
    private var writingStarted: Date?

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        a.current == b.current && a.pieces == b.pieces && a.finished.map(\.stage) == b.finished.map(\.stage)
    }

    public mutating func enter(_ stage: Stage, at now: Date = Date()) {
        close(at: now)
        current = stage
        currentStarted = now
        if stage == .writing, writingStarted == nil { writingStarted = now }
    }

    /// One piece of output (about one token) has arrived.
    public mutating func piece(at now: Date = Date()) {
        if current != .writing { enter(.writing, at: now) }
        pieces += 1
    }

    public mutating func finish(at now: Date = Date()) {
        close(at: now)
        current = nil
        currentStarted = nil
    }

    private mutating func close(at now: Date) {
        guard let current, let currentStarted else { return }
        finished.append((current, now.timeIntervalSince(currentStarted)))
    }

    public func perSecond(at now: Date = Date()) -> Double? {
        let seconds = finished.first { $0.stage == .writing }?.seconds ?? writingStarted.map { now.timeIntervalSince($0) } ?? 0
        return pieces > 1 && seconds > 0.2 ? Double(pieces) / seconds : nil
    }

    /// 「読み込み 3.0秒 · 入力 3.5秒 · 出力 18.6秒(10.8/秒)」, the running stage included.
    public func summary(at now: Date = Date()) -> String {
        var parts = finished
        if let current, let currentStarted { parts.append((current, now.timeIntervalSince(currentStarted))) }
        return parts.filter { $0.seconds >= 0.1 || $0.stage == current }.map { part in
            let time = "\(part.stage.rawValue) " + String(format: "%.1f秒", part.seconds)
            guard part.stage == .writing, let speed = perSecond(at: now) else { return time }
            return time + String(format: "(%.1f/秒)", speed)
        }.joined(separator: " · ")
    }
}
