import Foundation
import HarnessCore

extension TargetCoverage {
    /// Nominated symbols may be written in Swift selector form (`render(_:)`, `init?(code:)`) or qualified by their type
    /// (`LoanPolicy.of`). Declarations are indexed by bare name, so match the base name; this adds no acceptance path.
    static func baseName(_ symbol: String) -> String {
        var name = String(symbol.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
        while name.hasSuffix("?") || name.hasSuffix("!") { name.removeLast() }
        return name
    }

    /// Promotions allowed in one Target Replan: one per blocking gap requirement, at least the historical 2,
    /// never more than a nomination may carry. Each promotion still needs its own deterministic evidence.
    public static func promotionLimit(gaps: [Entry]) -> Int {
        min(TargetNomination.maximumItems, max(maximumPromotions, Set(gaps.map(\.requirementID)).count))
    }
}
