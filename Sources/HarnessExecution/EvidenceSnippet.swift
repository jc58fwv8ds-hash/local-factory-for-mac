import Foundation

/// Model-visible READ-ONLY evidence. Small files are shown whole (unchanged behaviour); larger
/// files are reduced to a few bounded windows chosen in this priority order:
/// 1. declarations of relevant symbols, 2. declarations of this file's types that other context
/// files use, 3. reference/use sites of relevant symbols, 4. the matched symbol (only when it is
/// informative, never a literal or generic keyword), 5. the start of the file as lexical fallback.
public enum EvidenceSnippet {
    public static let maximumCharacters = TargetDiscoveryPolicy.maximumSnippetCharacters
    public static let maximumWindows = 3
    static let declarationRadius = (before: 2, after: 24)
    static let useRadius = 6

    public static func select(source: String, relevant: [String], contextReferences: Set<String> = [],
                              matched: String? = nil, maximumCharacters: Int = maximumCharacters,
                              maximumWindows: Int = maximumWindows) -> String {
        guard maximumCharacters > 0, source.count > maximumCharacters else { return source }
        let lines = source.components(separatedBy: "\n")
        let symbols = Array(Set(relevant.filter(DeclarationSeedExpansion.isInformative))).sorted()
        let declarationPattern = #"\b(struct|class|actor|protocol|enum|typealias|func|var|let|case)\s+"#
        func declares(_ line: String, _ name: String) -> Bool {
            line.range(of: declarationPattern + NSRegularExpression.escapedPattern(for: name) + #"\b"#,
                       options: .regularExpression) != nil
        }
        func uses(_ line: String, _ name: String) -> Bool {
            line.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#, options: .regularExpression) != nil
        }
        var anchors: [(priority: Int, line: Int, before: Int, after: Int)] = []
        for (number, line) in lines.enumerated() {
            if symbols.contains(where: { declares(line, $0) }) {
                anchors.append((1, number, declarationRadius.before, declarationRadius.after))
            } else if let name = typeDeclarationName(line), contextReferences.contains(name) {
                anchors.append((2, number, declarationRadius.before, declarationRadius.after))
            } else if symbols.contains(where: { uses(line, $0) }) {
                anchors.append((3, number, useRadius, useRadius))
            }
        }
        if let matched, DeclarationSeedExpansion.isInformative(matched),
           let number = lines.firstIndex(where: { uses($0, matched) }) {
            anchors.append((4, number, 8, 8))
        }
        anchors.append((5, 0, 0, 30))
        // Choose windows by priority, then render them in source order.
        var chosen: [ClosedRange<Int>] = []
        var used = 0
        for anchor in anchors.sorted(by: { $0.priority == $1.priority ? $0.line < $1.line : $0.priority < $1.priority }) {
            guard chosen.count < maximumWindows else { break }
            let range = max(0, anchor.line - anchor.before)...min(lines.count - 1, anchor.line + anchor.after)
            if chosen.contains(where: { $0.overlaps(range) }) { continue }
            let size = lines[range].joined(separator: "\n").count + 40
            guard used + size <= maximumCharacters else { continue }
            chosen.append(range); used += size
        }
        if chosen.isEmpty {
            return TargetDiscoveryPolicy.boundedSnippet(source: source, symbol: nil, maximumCharacters: maximumCharacters)
        }
        let marker = "/* … bounded evidence … */"
        var parts: [String] = []
        for range in chosen.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > 0 { parts.append(marker) }
            parts.append(lines[range].joined(separator: "\n"))
        }
        if let last = chosen.map(\.upperBound).max(), last < lines.count - 1 { parts.append(marker) }
        return parts.joined(separator: "\n")
    }

    /// Public read-only views of the deterministic identifier scanner for the pilot stages.
    public static func identifiers(_ text: String) -> Set<String> { ContextRelationships.identifiers(text) }
    public static func typeDeclarations(_ source: String) -> Set<String> { ContextRelationships.typeDeclarations(source) }

    static func typeDeclarationName(_ line: String) -> String? {
        guard let match = line.range(of: #"\b(struct|class|actor|protocol|enum)\s+[A-Za-z_][A-Za-z0-9_]*"#,
                                     options: .regularExpression) else { return nil }
        return line[match].split(separator: " ").last.map(String.init)
    }
}
