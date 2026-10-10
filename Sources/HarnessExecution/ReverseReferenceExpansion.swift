import Foundation

/// One-hop read-only discovery from high-confidence declaration seeds; no permission grant.
public enum ReverseReferenceExpansion {
    public static let maximumFiles = 3
    public struct Evidence: Codable, Equatable, Sendable {
        public let seedSymbol: String
        public let sourceClause: String
        public let relationType: String
        public let candidateFile: String
        public let candidateSymbol: String
        public let score: Int
        public let reason: String
    }
    public static func discover(seeds: [RepositorySymbolIndex.Match], sources: [String: String],
                                alreadySelected: Set<String>, protected: Set<String>) -> [Evidence] {
        let clean = sources.filter { !protected.contains($0.key) }.mapValues(codeOnly)
        let index = RepositorySymbolIndex(sources: clean)
        let kinds: Set<RepositorySymbolIndex.Kind> = [.type, .protocolType, .enumeration, .function, .method]
        var matches: [Evidence] = []
        for seed in seeds where seed.score >= 100 && seed.evidenceType == "exact_identifier_declaration" {
            guard !protected.contains(seed.file), index.symbols.contains(where: {
                $0.file == seed.file && $0.name == seed.symbol && kinds.contains($0.kind)
            }) else { continue }
            // Ambiguous same-name declarations are not proof of a reference to this seed.
            let owners = Set(index.symbols.filter { $0.name == seed.symbol && kinds.contains($0.kind) }.map(\.file))
            guard owners == [seed.file] else { continue }
            for file in clean.keys.sorted() where file != seed.file && !alreadySelected.contains(file) {
                guard index.symbols.contains(where: { $0.file == file && $0.name == seed.symbol && $0.kind == .reference }) else { continue }
                let candidate = index.symbols.first { $0.file == file && kinds.contains($0.kind) }?.name ?? seed.symbol
                matches.append(.init(seedSymbol: seed.symbol, sourceClause: seed.clauseID,
                    relationType: "reference_usage", candidateFile: file, candidateSymbol: candidate, score: 70,
                    reason: "Code identifier references unique declaration in \(seed.file); depth=1; READ-ONLY"))
            }
        }
        let sorted = matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.candidateFile != $1.candidateFile { return $0.candidateFile < $1.candidateFile }
            if $0.seedSymbol != $1.seedSymbol { return $0.seedSymbol < $1.seedSymbol }
            return $0.sourceClause < $1.sourceClause
        }
        var seen = Set<String>()
        return Array(sorted.filter { seen.insert($0.candidateFile).inserted }.prefix(maximumFiles))
    }
    /// Mask comments and string literals before indexing; they are not executable usage.
    static func codeOnly(_ source: String) -> String {
        let pattern = #"(?s)/\*.*?\*/|//[^\n]*|\"\"\".*?\"\"\"|\"(?:\\.|[^\"\\])*\""#
        return source.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
}
