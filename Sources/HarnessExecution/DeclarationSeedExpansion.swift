import Foundation

/// Context retrieval recall. Seeds come from the main declarations of the files already in the
/// ContextSet (types, protocols, enums, and functions/methods/properties related to the objective),
/// not only from the literal or enum case that happened to match the objective. Files that
/// reference those seeds, and strong initial candidates with a code relation to the selection,
/// are added as READ-ONLY evidence only; nothing here grants edit rights.
public enum DeclarationSeedExpansion {
    public static let maximumFiles = ReverseReferenceExpansion.maximumFiles
    static let typeKinds: Set<RepositorySymbolIndex.Kind> = [.type, .protocolType, .enumeration]
    static let memberKinds: Set<RepositorySymbolIndex.Kind> = [.function, .method, .property]
    /// Literals and generic words never act as seeds or snippet anchors.
    static let generic: Set<String> = ["true", "false", "nil", "self", "Self", "super", "init", "return", "value", "values",
        "data", "error", "result", "type", "name", "names", "id", "count", "text", "string", "String", "Int", "Bool",
        "Double", "Date", "URL", "Data", "first", "last", "map", "filter", "items", "item", "some", "none", "default",
        "description", "rawValue", "hash", "key", "keys", "path", "index", "other", "lhs", "rhs", "Foundation"]

    public static func isInformative(_ symbol: String) -> Bool {
        symbol.count >= 3 && !generic.contains(symbol) && symbol.first.map { !$0.isNumber } == true
            && symbol.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    public struct Seed: Codable, Equatable, Sendable {
        public let file: String
        public let symbol: String
        public let kind: String
    }

    /// Declaration seeds of `files`. Type-like declarations of target files are always seeds;
    /// members are seeds only when they share an identifier subtoken with the objective.
    /// A seed name must be declared by exactly one indexed file (ambiguity is not evidence).
    public static func seeds(files: [String], targets: Set<String>, objective: String,
                             index: RepositorySymbolIndex) -> [Seed] {
        let objectiveTokens = Set(ContextRelationships.identifiers(objective).filter(isInformative)
            .flatMap(RepositorySymbolIndex.subtokens).filter { $0.count >= 3 })
        let declared = index.symbols.filter { typeKinds.contains($0.kind) || memberKinds.contains($0.kind) }
        var owners: [String: Set<String>] = [:]
        for symbol in declared { owners[symbol.name, default: []].insert(symbol.file) }
        var result: [Seed] = []
        for file in files.sorted() {
            for symbol in declared where symbol.file == file && isInformative(symbol.name) && owners[symbol.name] == [file] {
                let isType = typeKinds.contains(symbol.kind)
                let related = !Set(symbol.subtokens).isDisjoint(with: objectiveTokens)
                guard (isType && (targets.contains(file) || related)) || (!isType && related) else { continue }
                let seed = Seed(file: file, symbol: symbol.name, kind: symbol.kind.rawValue)
                if !result.contains(seed) { result.append(seed) }
            }
        }
        return result
    }

    /// One-hop READ-ONLY files that reference declaration seeds, plus retained strong initial
    /// candidates with a type relation to the selection. Deterministic and bounded.
    public static func expand(selected: [String], targets: Set<String>, objective: String,
                              initialCandidates: [RepositorySymbolIndex.Match], sources: [String: String],
                              protected: Set<String>, excluding: Set<String> = []) -> [ReverseReferenceExpansion.Evidence] {
        let clean = sources.filter { !protected.contains($0.key) }.mapValues(ReverseReferenceExpansion.codeOnly)
        let index = RepositorySymbolIndex(sources: clean)
        let seeds = seeds(files: selected, targets: targets, objective: objective, index: index)
        let skip = Set(selected).union(excluding).union(protected)
        func references(_ file: String) -> Set<String> {
            Set(index.symbols.filter { $0.file == file && $0.kind == .reference }.map(\.name))
        }
        var found: [(ReverseReferenceExpansion.Evidence, Int)] = []
        for file in clean.keys.sorted() where !skip.contains(file) && !file.contains("Tests/") {
            let used = seeds.filter { references(file).contains($0.symbol) }
            guard !used.isEmpty else { continue }
            let typeHits = used.filter { typeKinds.map(\.rawValue).contains($0.kind) }.count
            let weight = typeHits * 2 + (used.count - typeHits)
            let first = used.sorted { $0.symbol < $1.symbol }[0]
            found.append((.init(seedSymbol: first.symbol, sourceClause: "declaration", relationType: "declaration_reference",
                candidateFile: file, candidateSymbol: first.symbol, score: 60 + min(weight, 9),
                reason: "references \(used.map(\.symbol).sorted().prefix(4).joined(separator: ", ")) declared in "
                    + Set(used.map(\.file)).sorted().joined(separator: ", ") + "; depth=1; READ-ONLY"), weight))
        }
        // A strong initial candidate the selector did not keep stays READ-ONLY when it has a
        // type-level code relation to a selected file (either direction).
        let selectedTypes = Set(index.symbols.filter { selected.contains($0.file) && typeKinds.contains($0.kind) }.map(\.name))
        let selectedRefs = Set(selected.flatMap { references($0) })
        for candidate in initialCandidates where candidate.score >= 72 && !skip.contains(candidate.file)
            && isInformative(candidate.symbol) && clean[candidate.file] != nil
            && !found.contains(where: { $0.0.candidateFile == candidate.file }) {
            let ownTypes = Set(index.symbols.filter { $0.file == candidate.file && typeKinds.contains($0.kind) }.map(\.name))
            let uses = references(candidate.file).intersection(selectedTypes)
            let usedBy = ownTypes.intersection(selectedRefs)
            guard let relation = (uses.sorted().first.map { "references \($0) declared by a selected file" }
                ?? usedBy.sorted().first.map { "declares \($0) referenced by a selected file" }) else { continue }
            found.append((.init(seedSymbol: candidate.symbol, sourceClause: candidate.clauseID, relationType: "retained_candidate",
                candidateFile: candidate.file, candidateSymbol: candidate.symbol, score: 70,
                reason: "initial candidate (\(candidate.evidenceType)) kept: \(relation); READ-ONLY"), 10))
        }
        let ordered = found.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.candidateFile < $1.0.candidateFile
        }.map(\.0)
        return Array(ordered.prefix(maximumFiles))
    }
}
