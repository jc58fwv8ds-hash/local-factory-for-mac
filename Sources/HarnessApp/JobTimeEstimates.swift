import Foundation
import SwiftUI

/// How long a job the user asked for will still take (2026-11-04, the user: show it whenever a job runs). The guess is the
/// middle of the last runs of the same kind on this Mac; before the first run, a measured figure where there is one.
struct JobTimeEstimates {
    static let key = "harness.jobTimes"
    /// Measured on this Mac (2026-11-03/04) or noted in config/purpose-models.json.
    static let measured: [String: Double] = ["image:z-image-turbo": 60, "image:wan22-5b": 600,
                                             "image:wan22-5b-fast": 360, "agent": 15]
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(_ kind: String, seconds: Double) {
        guard seconds > 0 else { return }
        var all = defaults.dictionary(forKey: Self.key) as? [String: [Double]] ?? [:]
        all[kind] = Array(((all[kind] ?? []) + [seconds]).suffix(7))
        defaults.set(all, forKey: Self.key)
    }

    func expected(_ kind: String) -> Double? {
        let runs = (defaults.dictionary(forKey: Self.key) as? [String: [Double]])?[kind]?.sorted() ?? []
        if !runs.isEmpty { return runs[runs.count / 2] }
        // "image:wan22-5b@10s", never made at this length: the 3-second figure, in proportion.
        let parts = kind.split(separator: "@")
        if parts.count == 2, let seconds = Double(parts[1].dropLast()), let base = Self.measured[String(parts[0])] { return base * seconds / 3 }
        return Self.measured[kind]
    }

    /// "残り およそ 3 分". Past the guess it says so instead of counting below zero; with no guess, the time so far.
    static func text(expected: Double?, elapsed: Double) -> String {
        guard let expected else { return "経過 \(duration(elapsed))" }
        let left = expected - elapsed
        return left > 0 ? "残り およそ \(duration(left))" : "いつもより長くかかっています(経過 \(duration(elapsed)))"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(max(1, Int(seconds.rounded(.up)))) 秒" }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes < 60 ? "\(minutes) 分" : "\(minutes / 60) 時間 \(minutes % 60) 分"
    }
}

/// The remaining time of a running job, updated every second.
struct RemainingTimeLabel: View {
    let kind: String
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(JobTimeEstimates.text(expected: JobTimeEstimates().expected(kind), elapsed: context.date.timeIntervalSince(startedAt)))
                .font(.harness(.caption)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
