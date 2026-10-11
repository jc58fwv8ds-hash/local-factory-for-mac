import Foundation
import HarnessCore

/// Target Coverage: before any proposal, every requirement that needs a code change must
/// have an Editable Owner. When it has none but directly related read-only evidence exists,
/// the Harness allows one Target Replan in which the model nominates an existing file; the
/// nomination is promoted only on deterministic code evidence. Generic by construction:
/// symbols come from the plan, the objective and the code, never from task-specific rules.
public enum TargetCoverage {
    public enum State: String, Codable, Sendable { case COVERED, NO_CHANGE_REQUIRED, TARGET_COVERAGE_GAP }

    public struct Entry: Codable, Sendable, Equatable {
        public let requirementID: String
        public let requirement: String
        public let editableOwners: [String]
        public let readOnlyEvidence: [String]
        public let coverageState: State
        public let reason: String
        /// A gap stops the proposal only when directly related read-only evidence exists;
        /// otherwise the existing plan checks decide (behaviour unchanged).
        public let blocking: Bool
        public let newSymbols: [String]
        public let existingSymbols: [String]
    }

    public struct Verdict: Codable, Sendable, Equatable {
        public let requirementID: String
        public let file: String
        public let symbol: String
        public let accepted: Bool
        public let evidence: [String]
        public let rejection: String?
    }

    public static let maximumPromotions = 2

    // MARK: Editable Owner assessment

    public static func assess(_ plan: RequirementCoveragePlan, objective: String, editable: Set<String>,
                              readOnly: Set<String>, sources: [String: String]) -> [Entry] {
        let declared = sources.mapValues { ContextRelationships.declarations($0).all }
        let declaredTypes = sources.mapValues { ContextRelationships.typeDeclarations($0) }
        let known = sources.values.reduce(into: Set<String>()) { $0.formUnion(ContextRelationships.identifiers($1)) }
        let objectiveIDs = ContextRelationships.identifiers(objective)
        return plan.requirements.enumerated().map { index, item in
            let id = "R\(index + 1)"
            let candidates = symbols(of: item)
            // A name that appears nowhere in the code and looks like an identifier (or is
            // named by the objective) must be introduced: the requirement needs a change.
            var new = candidates.filter { !known.contains($0) && (isCodeShaped($0) || objectiveIDs.contains($0)) }
            // An objective identifier the requirement attaches to a named type, but which no
            // file declaring that type declares, is a member still to be added to that type.
            let hosts = declaredTypes.filter { !$0.value.isDisjoint(with: candidates) }.map(\.key)
            if !hosts.isEmpty {
                new.formUnion(candidates.filter { name in
                    isCodeShaped(name) && objectiveIDs.contains(name) && !declaredTypes.values.contains { $0.contains(name) }
                        && hosts.allSatisfy { !(declared[$0] ?? []).contains(name) }
                })
            }
            let existing = candidates.subtracting(new).filter { name in declared.values.contains { $0.contains(name) } }
            let targets = Set(item.editable_targets.filter { sources[$0] != nil })
            // Edit requests for READ-ONLY files: never satisfied by another editable file that merely
            // declares a shared symbol; they are routed to Target Replan (never promoted directly).
            let readOnlyTargets = targets.intersection(readOnly)
            let needsChange = !targets.isEmpty || !new.isEmpty
            let owners = editable.filter { file in
                targets.contains(file) || !(declared[file] ?? []).isDisjoint(with: existing)
            }
            let cited = Set(item.read_only_evidence).union(targets)
            let related = readOnly.filter { file in
                !(declared[file] ?? []).isDisjoint(with: existing)
                    || (cited.contains(file) && !ContextRelationships.identifiers(sources[file] ?? "").isDisjoint(with: existing))
            }
            func entry(_ state: State, _ reason: String, blocking: Bool = false) -> Entry {
                .init(requirementID: id, requirement: item.requirement, editableOwners: owners.sorted(),
                      readOnlyEvidence: related.sorted(), coverageState: state, reason: reason, blocking: blocking,
                      newSymbols: new.sorted(), existingSymbols: existing.sorted())
            }
            guard needsChange else {
                // A missing target is not a reason: NO_CHANGE_REQUIRED needs a concrete no-change reason.
                let why = (item.no_change_reason ?? "").trimmingCharacters(in: .whitespaces)
                if item.coverage == "complete", isConcreteNoChangeReason(why, paths: Array(sources.keys)) {
                    return entry(.NO_CHANGE_REQUIRED, why)
                }
                // A shared declaration alone does not own a behaviour change: the editable file must
                // implement a named function, consume a symbol declared elsewhere, or be the only site.
                // READ-ONLY files that use a requirement symbol are behaviour sites too (declaration/use relation).
                let informative = existing.filter(DeclarationSeedExpansion.isInformative)
                let users = readOnly.filter { !ContextRelationships.identifiers(sources[$0] ?? "").isDisjoint(with: informative) }
                let sites = related.union(users)
                let editableUsers = editable.filter { !ContextRelationships.identifiers(sources[$0] ?? "").isDisjoint(with: informative) }
                let behaviourOwners = Self.behaviourOwners(owners.union(editableUsers), alternatives: sites,
                                                           existing: informative, sources: sources)
                if !behaviourOwners.isEmpty {
                    return entry(.COVERED, "editable owner: " + behaviourOwners.sorted().joined(separator: ", ")
                        + "; no concrete no-change reason")
                }
                guard !existing.isEmpty, !sites.isEmpty else {
                    return entry(.TARGET_COVERAGE_GAP, "no concrete no-change reason; no editable owner and no directly "
                        + "related read-only evidence (not blocking)")
                }
                let note = owners.isEmpty ? "" : "; editable files only share declarations: " + owners.sorted().joined(separator: ", ")
                return Entry(requirementID: id, requirement: item.requirement, editableOwners: [],
                    readOnlyEvidence: sites.sorted(), coverageState: .TARGET_COVERAGE_GAP,
                    reason: "behaviour change on existing symbols without a concrete no-change reason; no behaviour owner"
                        + note + "; related read-only evidence: " + sites.sorted().joined(separator: ", "),
                    blocking: true, newSymbols: new.sorted(), existingSymbols: existing.sorted())
            }
            if !readOnlyTargets.isEmpty {
                let requested = readOnlyTargets.sorted().joined(separator: ", ")
                guard !related.isEmpty else {
                    return entry(.TARGET_COVERAGE_GAP, "edit requested for READ-ONLY \(requested); no directly related "
                        + "read-only evidence (not blocking)")
                }
                return entry(.TARGET_COVERAGE_GAP, "edit requested for READ-ONLY \(requested); routed to Target Replan; "
                    + "related read-only evidence: " + related.sorted().joined(separator: ", "), blocking: true)
            }
            if !owners.isEmpty {
                return entry(.COVERED, "editable owner: " + owners.sorted().joined(separator: ", "))
            }
            let because = new.isEmpty ? "plan lists only non-editable targets" : "introduces " + new.sorted().joined(separator: ", ")
            guard !related.isEmpty else {
                return entry(.TARGET_COVERAGE_GAP, "\(because); no editable owner and no directly related read-only evidence (not blocking)")
            }
            return entry(.TARGET_COVERAGE_GAP, "\(because); no editable owner; related read-only evidence: "
                + related.sorted().joined(separator: ", "), blocking: true)
        }
    }

    /// Editable files that own a behaviour-only requirement: they implement a named function or
    /// method, or consume a requirement symbol declared in another file. Only when no READ-ONLY
    /// related file does either are plain declaring files accepted as the sole site.
    static func behaviourOwners(_ candidates: Set<String>, alternatives: Set<String>, existing: Set<String>,
                                sources: [String: String]) -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        let index = RepositorySymbolIndex(sources: sources)
        let declaredBy = sources.mapValues { ContextRelationships.declarations($0).all }
        func implements(_ file: String) -> Bool {
            index.symbols.contains { $0.file == file && ($0.kind == .function || $0.kind == .method) && existing.contains($0.name) }
        }
        func consumes(_ file: String) -> Bool {
            let used = Set(index.symbols.filter { $0.file == file && $0.kind == .reference }.map(\.name)).intersection(existing)
            return used.contains { name in declaredBy.contains { $0.key != file && $0.value.contains(name) } }
        }
        let direct = candidates.filter { implements($0) || consumes($0) }
        if !direct.isEmpty { return direct }
        return alternatives.contains(where: { implements($0) || consumes($0) }) ? [] : candidates
    }

    public static func blockingGaps(_ entries: [Entry]) -> [Entry] {
        entries.filter { $0.coverageState == .TARGET_COVERAGE_GAP && $0.blocking }
    }

    // MARK: Nomination verification

    /// Deterministic verification of one nomination. Requires (1) an existing, writable,
    /// non-test file; (2) a symbol that exists in that file, or a new symbol of the gap
    /// requirement; (3) a requirement anchor: the file is directly related evidence of a
    /// gap requirement; (4) at least one task anchor: objective identifier, dependency or
    /// call relation with an editable target, shared constraint value, or a related test.
    public static func verify(_ nomination: TargetNomination.Item, gaps: [Entry], objective: String,
                              editable: Set<String>, sources: [String: String], tests: [String: String],
                              protected: Set<String>) -> Verdict {
        let tests = tests.filter { !protected.contains($0.key) }
        let file = nomination.file.trimmingCharacters(in: .whitespaces)
        let symbol = baseName(nomination.symbol)
        func verdict(_ requirement: String, _ evidence: [String], _ rejection: String?) -> Verdict {
            .init(requirementID: requirement, file: file, symbol: symbol, accepted: rejection == nil,
                  evidence: evidence, rejection: rejection)
        }
        let named = nomination.requirement_id
        guard !file.isEmpty, !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else {
            return verdict(named, [], "invalidPath")
        }
        if protected.contains(file) || file.contains("Tests/") { return verdict(named, [], "protectedOrTest") }
        guard let source = sources[file] else { return verdict(named, [], "fileNotFound") }
        if editable.contains(file) { return verdict(named, [], "alreadyEditable") }
        // Prefer the requirement the model named; fall back to any gap this file relates to.
        let candidates = gaps.filter { $0.readOnlyEvidence.contains(file) }
        guard let gap = candidates.first(where: { $0.requirementID == named }) ?? candidates.first else {
            return verdict(named, [], gaps.contains { $0.requirementID == named } ? "notRelatedToRequirement" : "requirementNotInGap")
        }
        let own = ContextRelationships.declarations(source)
        let references = ContextRelationships.identifiers(source)
        var evidence: [String] = []
        if !symbol.isEmpty {
            let exists = sources.values.contains { ContextRelationships.declarations($0).all.contains(symbol) }
            if own.all.contains(symbol) { evidence.append("definition: declares \(symbol)") }
            else if exists && references.contains(symbol) { evidence.append("reference: references \(symbol)") }
            else if gap.newSymbols.contains(symbol) { evidence.append("new symbol \(symbol) introduced by \(gap.requirementID)") }
            else { return verdict(gap.requirementID, [], exists ? "symbolNotInFile" : "symbolNotFound") }
        }
        let requirementDefinitions = own.all.intersection(gap.existingSymbols).sorted()
        evidence += requirementDefinitions.map { "definition: declares requirement symbol \($0)" }
        if requirementDefinitions.isEmpty {
            evidence += references.intersection(gap.existingSymbols).sorted().map { "reference: uses requirement symbol \($0)" }
        }
        var anchors: [String] = []
        for name in own.all.intersection(ContextRelationships.identifiers(objective)).filter({ $0.count >= 4 }).sorted() {
            anchors.append("objective: declares objective identifier \(name)")
        }
        for target in editable.sorted() {
            let targetSource = sources[target] ?? ""
            let targetRefs = ContextRelationships.identifiers(targetSource)
            let targetTypes = ContextRelationships.typeDeclarations(targetSource)
            for type in own.types.intersection(targetRefs).subtracting(targetTypes).sorted() {
                anchors.append("dependency: declares \(type) referenced by editable \(target)")
            }
            for type in references.intersection(targetTypes).subtracting(own.types).sorted() {
                anchors.append("dependency: references \(type) declared by editable \(target)")
            }
            for member in own.all.subtracting(own.types).intersection(targetRefs).intersection(gap.existingSymbols).sorted() {
                anchors.append("call: editable \(target) uses \(member) declared here")
            }
        }
        if editable.isEmpty {
            // No editable target to relate to: accept deterministic relations among the gap's
            // READ-ONLY files and identifier subtokens shared with the objective.
            for peer in Set(gaps.flatMap(\.readOnlyEvidence)).subtracting([file]).sorted() {
                let peerSource = sources[peer] ?? ""
                let peerRefs = ContextRelationships.identifiers(peerSource)
                let peerTypes = ContextRelationships.typeDeclarations(peerSource)
                for type in own.types.intersection(peerRefs).subtracting(peerTypes).sorted() {
                    anchors.append("peer: declares \(type) referenced by READ-ONLY \(peer)")
                }
                for type in references.intersection(peerTypes).subtracting(own.types).sorted() {
                    anchors.append("peer: references \(type) declared by READ-ONLY \(peer)")
                }
            }
            let objectiveTokens = Set(ContextRelationships.identifiers(objective).filter(DeclarationSeedExpansion.isInformative)
                .flatMap(RepositorySymbolIndex.subtokens).filter { $0.count >= 4 })
            for name in own.all.filter(DeclarationSeedExpansion.isInformative).sorted() {
                let overlap = Set(RepositorySymbolIndex.subtokens(name)).intersection(objectiveTokens)
                if !overlap.isEmpty { anchors.append("clause: declares \(name) sharing \(overlap.sorted().joined(separator: ", ")) with the objective") }
            }
        }
        let values = ContextRelationships.constraintValues(source)
        let shared = ContextRelationships.constraintValues(objective)
            .union(editable.flatMap { ContextRelationships.constraintValues(sources[$0] ?? "") })
        for value in values.intersection(shared).sorted() { anchors.append("shared constant \(value)") }
        let testAnchors = own.types.union(own.all.intersection(gap.existingSymbols)).filter { $0.count >= 4 }
        for (test, testSource) in tests.sorted(by: { $0.key < $1.key }) {
            if let name = ContextRelationships.identifiers(testSource).intersection(testAnchors).sorted().first {
                anchors.append("test: \(test) references \(name) declared here")
            }
        }
        guard !anchors.isEmpty else { return verdict(gap.requirementID, evidence, "insufficientEvidence") }
        return verdict(gap.requirementID, evidence + anchors, nil)
    }

    /// Requirements that were blocking gaps and are now COVERED get their verified owners
    /// as editable targets, so the accepted plan names every file the proposal may change.
    public static func patch(_ plan: RequirementCoveragePlan, before: [Entry], after: [Entry]) -> RequirementCoveragePlan {
        .init(requirements: plan.requirements.enumerated().map { index, item in
            guard index < before.count, index < after.count, before[index].blocking,
                  after[index].coverageState == .COVERED else { return item }
            let owners = after[index].editableOwners
            return .init(requirement: item.requirement, source_clause_ids: item.source_clause_ids,
                         relevant_symbols: item.relevant_symbols, editable_targets: owners,
                         read_only_evidence: item.read_only_evidence.filter { !owners.contains($0) },
                         rationale: item.rationale, coverage: "complete", no_change_reason: "", example: item.example)
        })
    }

    /// A no-change reason is concrete when the plan marks the requirement complete and the reason
    /// argues about behaviour, not about scope: it must not justify "no change" by a file being
    /// read-only, not editable or not shown (which is a target gap, not a no-change requirement).
    static func isConcreteNoChangeReason(_ reason: String, paths: [String]) -> Bool {
        let text = reason.lowercased()
        guard text.count >= 8 else { return false }
        let scopePhrases = ["read-only", "readonly", "read only", "editable", "not provided", "not shown", "not present",
                            "not available", "not included", "cannot edit", "can't edit", "cannot be modified", "cannot modify",
                            "読み取り専用", "編集でき", "編集不可"]
        if scopePhrases.contains(where: text.contains) { return false }
        let names = paths.flatMap { [$0.lowercased(), ($0 as NSString).lastPathComponent.lowercased()] }
        return !names.contains(where: text.contains)
    }

    // MARK: Symbols

    /// Plan symbols (dotted names split into components) plus identifier-shaped tokens of
    /// the requirement text itself.
    static func symbols(of item: RequirementCoveragePlan.Item) -> Set<String> {
        var names = Set<String>()
        for raw in item.relevant_symbols {
            for part in raw.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }) where part.count >= 4 {
                names.insert(String(part))
            }
        }
        names.formUnion(ContextRelationships.identifiers(item.requirement).filter(isCodeShaped))
        return names.filter { $0.first.map { !$0.isNumber } ?? false }
    }

    /// lowerCamelCase with an interior capital, UpperCamelCase with two humps, or snake_case.
    static func isCodeShaped(_ name: String) -> Bool {
        guard name.count >= 4, name.allSatisfy({ $0.isASCII }) else { return false }
        if name.contains("_") { return name.contains { $0.isLetter } }
        let uppers = name.filter(\.isUppercase).count
        guard uppers < name.count else { return false }
        return name.first!.isLowercase ? uppers >= 1 : uppers >= 2
    }

    // MARK: Prompt

    /// Target Replan prompt: the gap requirements, current EditableTargets, the related
    /// read-only evidence and the deterministic relation evidence only.
    public static func nominationPrompt(objective: String, gaps: [Entry], editable: [String: String],
                                        evidence: [String: String]) throws -> String {
        let rows = gaps.map { gap in
            ["requirement_id": gap.requirementID, "requirement": gap.requirement,
             "new_symbols": gap.newSymbols, "existing_symbols": gap.existingSymbols,
             "related_read_only_files": gap.readOnlyEvidence,
             "relation_evidence": gap.readOnlyEvidence.map { file in
                 let source = evidence[file] ?? ""
                 let declared = ContextRelationships.declarations(source).all.intersection(gap.existingSymbols).sorted()
                 let used = ContextRelationships.identifiers(source).intersection(gap.existingSymbols).subtracting(declared).sorted()
                 return "\(file) declares [\(declared.joined(separator: ", "))] uses [\(used.joined(separator: ", "))]"
             }] as [String: Any]
        }
        func json(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        return """
        These requirements need a code change but no EDITABLE file owns them. For each one, name the existing \
        READ-ONLY file that must become editable and the existing symbol in it that the change belongs to \
        (or the new symbol you will add there). Nominate only files listed in related_read_only_files; nominate \
        nothing for a requirement that truly needs no change. The Harness verifies every nomination against the \
        code and rejects unsupported ones; nomination alone never grants edit rights.
        Objective: \(objective)
        Requirements without an editable owner: \(try json(rows))
        EDITABLE (current): \(try json(Array(editable.keys).sorted()))
        READ-ONLY evidence: \(try json(evidence))
        Return JSON only: {"nominations":[{"requirement_id":"...","file":"...","symbol":"...","relation":"...","why_edit":"..."}]}.
        """
    }
}
