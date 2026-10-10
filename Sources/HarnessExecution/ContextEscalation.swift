import Foundation
import HarnessCore

/// Missing-Context Escalation: the model may ask once, in structured form, for a file
/// or symbol it cannot see or may not edit. The Harness admits it only on deterministic
/// code evidence; the model never gets free exploration.
public enum ContextEscalation {
    public static let maximumPerTask = 1
    public static let maximumFiles = 2

    public struct Decision: Sendable, Equatable {
        public let accepted: Bool
        public let addToContext: [String]
        public let promoteToEditable: [String]
        public let evidence: [String: [String]]
        public let rejection: String?
    }

    public static func admit(escalationsUsed: Int) -> Bool { escalationsUsed < maximumPerTask }

    /// `sources`: every readable non-protected source file (path → content).
    public static func evaluate(_ request: StructuredEditBatch.ContextRequest, objective: String,
                                targets: [String], contextSet: [String], sources: [String: String],
                                protected: Set<String>) -> Decision {
        func reject(_ why: String) -> Decision {
            .init(accepted: false, addToContext: [], promoteToEditable: [], evidence: [:], rejection: why)
        }
        guard request.operation == "read" || request.operation == "edit" else { return reject("invalidOperation") }
        guard !request.why_needed.trimmingCharacters(in: .whitespaces).isEmpty else { return reject("missingWhyNeeded") }
        // Resolve candidates: an existing path, and/or files that declare the symbol.
        var candidates: [String] = []
        if let file = request.file, !file.isEmpty {
            guard !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else { return reject("invalidPath") }
            if protected.contains(file) || isTest(file) { return reject("protectedOrTest") }
            if sources[file] != nil { candidates.append(file) }
        }
        if let symbol = request.symbol, !symbol.isEmpty {
            let declaring = sources.keys.sorted().filter {
                ContextRelationships.declarations(sources[$0] ?? "").all.contains(symbol)
            }
            candidates += declaring.filter { !candidates.contains($0) }
        }
        candidates = candidates.filter { !protected.contains($0) && !isTest($0) }
        guard !candidates.isEmpty else { return reject("fileOrSymbolNotFound") }
        guard candidates.count <= maximumFiles else { return reject("ambiguousRequest") }

        let targetTypes = Set(targets.flatMap { ContextRelationships.typeDeclarations(sources[$0] ?? "") })
        let targetReferences = Set(targets.flatMap { ContextRelationships.identifiers(sources[$0] ?? "") })
        let targetValues = Set(targets.flatMap { ContextRelationships.constraintValues(sources[$0] ?? "") })
        let objectiveIdentifiers = ContextRelationships.identifiers(objective)
        let objectiveValues = ContextRelationships.constraintValues(objective)
        var add: [String] = [], promote: [String] = [], evidence: [String: [String]] = [:]
        for path in candidates {
            let source = sources[path] ?? ""
            let own = ContextRelationships.declarations(source)
            var direct: [String] = [], weak: [String] = []
            for type in own.types.intersection(targetReferences).subtracting(targetTypes).sorted() {
                direct.append("defines \(type) referenced by target")
            }
            let values = ContextRelationships.constraintValues(source)
            for value in values.intersection(objectiveValues.union(targetValues)).sorted() {
                direct.append("shares constraint value \(value) with objective/target")
            }
            for symbol in own.all.intersection(objectiveIdentifiers).filter({ $0.count >= 4 }).sorted() {
                direct.append("declares objective identifier \(symbol)")
            }
            if let type = ContextRelationships.identifiers(source).intersection(targetTypes).sorted().first {
                weak.append("uses target type \(type)")
            }
            guard !(direct + weak).isEmpty else { continue }
            evidence[path] = direct + weak
            if !contextSet.contains(path) { add.append(path) }
            // Editing needs an explicit edit request AND a direct code relation.
            if request.operation == "edit", !direct.isEmpty, !targets.contains(path) { promote.append(path) }
        }
        guard !evidence.isEmpty else { return reject("noRelationEvidence") }
        if request.operation == "edit" && promote.isEmpty && !candidates.contains(where: targets.contains) {
            return .init(accepted: false, addToContext: add, promoteToEditable: [], evidence: evidence,
                         rejection: "insufficientEditRationale")
        }
        return .init(accepted: true, addToContext: add, promoteToEditable: promote, evidence: evidence, rejection: nil)
    }

    /// An edit aimed at a file outside the editable targets is treated as an implicit
    /// request, but only for paths that exist; invented paths stay scope violations.
    public static func implicitRequest(fromEditsIn batch: StructuredEditBatch, editable: Set<String>,
                                       sources: [String: String]) -> StructuredEditBatch.ContextRequest? {
        guard let path = batch.edits.map(\.file).first(where: { !editable.contains($0) }),
              sources[path] != nil else { return nil }
        return .init(file: path, symbol: nil, why_needed: "proposed edit to a non-editable file",
                     relation: "implied by proposal", operation: "edit")
    }

    private static func isTest(_ path: String) -> Bool { path.hasPrefix("Tests/") || path.contains("Tests/") }
}
