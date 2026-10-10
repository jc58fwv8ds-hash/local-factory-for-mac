import Foundation

/// One-hop, bounded expansion from the initial selection using code relationships,
/// never a task vocabulary: definitions/references between files, symbols stated in
/// the objective, and shared distinctive constraint values. Each addition keeps its
/// reasons so precision can be audited.
enum ContextRelationships {
    static let admissionScore = 40
    static let maximumAdditions = 2

    static func expand(objective: String, seeds: [String], candidates: [String],
                       sources: [String: String], lexical: [String: Int],
                       maximumTotal: Int = 5) -> [(path: String, reasons: [String], score: Int)] {
        let room = min(maximumAdditions, maximumTotal - seeds.count)
        guard room > 0 else { return [] }
        let declared = sources.mapValues(declarations)
        let seedTypes = Set(seeds.flatMap { declared[$0]?.types ?? [] })
        let seedSymbols = Set(seeds.flatMap { declared[$0]?.all ?? [] })
        let seedReferences = Set(seeds.flatMap { identifiers(sources[$0] ?? "") })
        let objectiveSymbols = identifiers(objective).filter { $0.count >= 4 }
        let objectiveValues = constraintValues(objective)
        let seedValues = Set(seeds.flatMap { constraintValues(sources[$0] ?? "") })
        // A value repeated across many files is a convention, not a shared constraint.
        var valueSpread: [String: Int] = [:]
        for source in sources.values { for value in constraintValues(source) { valueSpread[value, default: 0] += 1 } }

        var ranked: [(path: String, score: Int, reasons: [String])] = []
        for path in candidates where !seeds.contains(path) {
            guard let source = sources[path], let own = declared[path] else { continue }
            var score = 0
            var reasons: [String] = []
            for symbol in objectiveSymbols.intersection(own.all).subtracting(seedSymbols).sorted() {
                score += 50; reasons.append("defines objective symbol \(symbol)")
            }
            for type in own.types.intersection(seedReferences).subtracting(seedTypes).sorted().prefix(2) {
                score += 40; reasons.append("defines \(type) referenced by selected file")
            }
            let values = constraintValues(source).filter { valueSpread[$0, default: 0] <= 3 }
            for value in values.intersection(objectiveValues).sorted() {
                score += 40; reasons.append("shares constraint value \(value) with objective")
            }
            for value in values.intersection(seedValues).sorted() {
                score += 30; reasons.append("shares constraint value \(value) with selected file")
            }
            if let type = identifiers(source).intersection(seedTypes).sorted().first {
                score += 15; reasons.append("uses selected type \(type)")
            }
            score += min(10, lexical[path, default: 0] / 4)
            if score >= admissionScore { ranked.append((path, score, reasons)) }
        }
        return ranked.sorted { $0.score == $1.score ? $0.path < $1.path : $0.score > $1.score }
            .prefix(room).map { ($0.path, $0.reasons, $0.score) }
    }

    static func typeDeclarations(_ source: String) -> Set<String> { declarations(source).types }

    static func declarations(_ source: String) -> (types: Set<String>, all: Set<String>) {
        var types = Set<String>(), all = Set<String>()
        let pattern = #"\b(struct|enum|class|actor|protocol|typealias|func|let|var|case)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ([], []) }
        let text = source as NSString
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let kind = text.substring(with: match.range(at: 1)), name = text.substring(with: match.range(at: 2))
            all.insert(name)
            if ["struct", "enum", "class", "actor", "protocol", "typealias"].contains(kind) { types.insert(name) }
        }
        return (types, all)
    }

    static func identifiers(_ text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#) else { return [] }
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
    }

    /// Distinctive numeric limits (>= 5 digits), normalised across `_` and `,` separators.
    static func constraintValues(_ text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(?<!\d\.)\d[\d_,]*\d(?![A-Za-z0-9_])"#) else { return [] }
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let digits = ns.substring(with: match.range).filter(\.isNumber)
            guard digits.count >= 5, let value = UInt64(digits), value > 0 else { return nil }
            return String(value)
        })
    }
}
