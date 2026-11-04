import Foundation

/// How far today's video is (2026-11-04, the user: a job of hours needs a bar), from progress.json, which run_daily.sh and
/// daily_news.py keep up to date.
struct DailyNewsProgress: Codable, Equatable {
    var state: String
    var stage: String
    var detail: String
    var fraction: Double
    var startedAt: Double
    var pid: Int32

    static func read(_ file: URL) -> DailyNewsProgress? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    /// A job that says it is running but whose process is gone was stopped from outside (a restart, a crash).
    func isRunning(alive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool { state == "running" && alive(pid) }

    func isStopped(alive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool {
        state == "failed" || (state == "running" && !alive(pid))
    }

    /// "1 時間 20 分" from the speed so far; nil until there is enough to go on.
    func remaining(now: Double) -> String? {
        guard fraction >= 0.05, fraction < 1, now > startedAt else { return nil }
        let minutes = Int(((now - startedAt) * (1 - fraction) / fraction / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60) 時間 \(minutes % 60) 分" : "\(minutes) 分"
    }
}
