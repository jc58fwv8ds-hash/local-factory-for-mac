import Foundation
import HarnessCore

public enum TargetDiscoveryPolicy {
    public static let maximumPerTask = 1
    public static let maximumFiles = 5
    public static let maximumSnippetCharacters = 4_000

    public struct Budget: Sendable {
        public private(set) var used = 0
        public init() {}
        public mutating func consume() -> Bool {
            guard used < TargetDiscoveryPolicy.maximumPerTask else { return false }
            used += 1; return true
        }
    }

    public static func promotionEvidence(file: String, plan: RequirementCoveragePlan,
                                         candidates: [RepositorySymbolIndex.Match],
                                         sources: [String: String]) -> [String]? {
        let relevant = candidates.filter { $0.file == file }
        guard !relevant.isEmpty, sources[file] != nil else { return nil }
        let cited = Set(plan.requirements.filter { $0.editable_targets.contains(file) }.flatMap(\.source_clause_ids))
        guard let match = relevant.sorted(by: { $0.score == $1.score ? $0.symbol < $1.symbol : $0.score > $1.score })
            .first(where: { cited.contains($0.clauseID) }) else { return nil }
        let index = RepositorySymbolIndex(sources: sources)
        guard index.contains(file: file, symbol: match.symbol) else { return nil }
        return ["validated discovery symbol \(match.symbol)", "\(match.evidenceType): \(match.reason)",
                "coverage plan cites \(match.clauseID)"]
    }

    /// Keep model-visible discovery context bounded while deterministic validators retain
    /// the complete source. The window is stable and centred near the selected symbol.
    public static func boundedSnippet(source: String, symbol: String?, maximumCharacters: Int = maximumSnippetCharacters) -> String {
        guard maximumCharacters > 0, source.count > maximumCharacters else { return source }
        let midpoint: String.Index
        if let symbol, let range = source.range(of: symbol) {
            midpoint = range.lowerBound
        } else {
            midpoint = source.startIndex
        }
        let midpointOffset = source.distance(from: source.startIndex, to: midpoint)
        let startOffset = max(0, min(midpointOffset - maximumCharacters / 3, source.count - maximumCharacters))
        let start = source.index(source.startIndex, offsetBy: startOffset)
        let end = source.index(start, offsetBy: maximumCharacters)
        let prefix = start == source.startIndex ? "" : "/* … bounded discovery context … */\n"
        let suffix = end == source.endIndex ? "" : "\n/* … bounded discovery context … */"
        return prefix + source[start..<end] + suffix
    }
}
