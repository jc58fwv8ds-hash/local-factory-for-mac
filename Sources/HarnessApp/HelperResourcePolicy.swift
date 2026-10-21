import Foundation

/// The helper Mac's 16 GB is shared by the light-job model (8B, about 6.3 GB resident) and the split-reading tail (1.5-3.3
/// GB). Measured 2026-10-21 on the M4 Air: tail alone 79% free, both loaded 33% free, no new swap. When memory runs short
/// or the Mac warns of heat, a role is let go, the light model first (its jobs simply run on this Mac), then the tail
/// (Backburner reads alone again by itself). This Mac's own work is never slowed down to keep the helper busy.
enum HelperResourcePolicy {
    enum Role: String, Equatable, Sendable { case lightModel, splitTail }

    struct Health: Equatable, Sendable {
        var freePercent: Int
        var thermalWarning: Bool
    }

    /// `memory_pressure -Q` (last line "System-wide memory free percentage: N%") and `pmset -g therm` from the helper.
    static func health(from report: String) -> Health? {
        guard let range = report.range(of: #"free percentage:\s*(\d+)%"#, options: .regularExpression),
              let percent = Int(report[range].filter(\.isNumber)) else { return nil }
        // pmset says "No thermal warning level has been recorded" when all is well; any recorded level counts as a warning.
        let warned = report.range(of: #"(?i)thermal warning level\s*[:=]?\s*\d+"#, options: .regularExpression) != nil
            || report.contains("CPU_Speed_Limit") && report.range(of: #"CPU_Speed_Limit\s*=\s*100\b"#, options: .regularExpression) == nil
        return Health(freePercent: percent, thermalWarning: warned)
    }

    /// The roles to let go now, in order.
    static func rolesToRelease(_ health: Health) -> [Role] {
        if health.freePercent < 10 { return [.lightModel, .splitTail] }
        if health.freePercent < 20 || health.thermalWarning { return [.lightModel] }
        return []
    }
}
