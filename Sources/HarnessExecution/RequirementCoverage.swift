import Foundation
import HarnessCore

/// Harness-side, mechanical checks of a RequirementCoveragePlan, under-escalation
/// detection, bounded recovery budget, and leak-free replan prompts.
public enum RequirementCoverage {
    public enum Status: String, Codable, Sendable {
        /// Every requirement has editable targets or an explicit no-change reason.
        case ready
        /// The plan names existing non-editable files as edit targets: the Harness must
        /// verify them with ContextEscalation before any promotion.
        case planRequestsEscalation
        /// A requirement lacks a target/no-change reason (or touches symbols owned by
        /// read-only evidence it did not account for) while related evidence exists.
        case needsContextReplan
        /// Uncovered and no related evidence: the task cannot proceed.
        case incomplete
    }

    public struct Assessment: Sendable, Equatable {
        public let status: Status
        public let requestedFiles: [String]
        public let uncovered: [String]
        public let relatedEvidence: [String]
        public let invalidTargets: [String]
    }

    public static func assess(_ plan: RequirementCoveragePlan, editable: Set<String>, readOnly: Set<String>,
                              sources: [String: String]) -> Assessment {
        var requested = Set<String>(), invalid = Set<String>()
        var uncovered: [String] = [], related = Set<String>()
        let owners = readOnly.reduce(into: [String: Set<String>]()) { result, path in
            result[path] = ContextRelationships.declarations(sources[path] ?? "").all
        }
        for item in plan.requirements {
            let targets = Set(item.editable_targets.filter { !$0.isEmpty })
            invalid.formUnion(targets.filter { sources[$0] == nil })
            requested.formUnion(targets.filter { !editable.contains($0) && sources[$0] != nil })
            let accounted = Set(item.read_only_evidence).union(targets)
            // Symbols the requirement relies on that only a read-only file declares,
            // and which the plan neither edits nor cites as read-only evidence.
            let symbols = Set(item.relevant_symbols.filter { $0.count >= 4 })
            // A symbol also declared by any editable file is not owned exclusively by read-only evidence.
            let declaredByTargets = Set(targets.union(editable).flatMap { ContextRelationships.declarations(sources[$0] ?? "").all })
            let unaccountedOwners = owners.filter { path, declared in
                !accounted.contains(path) && !declared.intersection(symbols).subtracting(declaredByTargets).isEmpty
            }.map(\.key)
            let hasTarget = !targets.isEmpty && targets.allSatisfy { sources[$0] != nil }
            let hasReason = targets.isEmpty && !(item.no_change_reason ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            let satisfied = item.coverage == "complete" && (hasTarget || hasReason) && unaccountedOwners.isEmpty
            guard !satisfied else { continue }
            uncovered.append(item.requirement)
            related.formUnion(unaccountedOwners)
            related.formUnion(item.read_only_evidence.filter(readOnly.contains))
        }
        let status: Status = !requested.isEmpty ? .planRequestsEscalation
            : uncovered.isEmpty && invalid.isEmpty ? .ready
            : !related.isEmpty ? .needsContextReplan : .incomplete
        return .init(status: status, requestedFiles: requested.sorted(), uncovered: uncovered,
                     relatedEvidence: related.sorted(), invalidTargets: invalid.sorted())
    }

    /// Placeholder written for a new production file before the proposal edits it (anchor for replace_exact).
    public static let newFilePlaceholder = "import Foundation\n"
    public static let maximumNewFiles = 2

    /// New production files a plan may create: `Sources/<existing target>/<UpperCamelName>.swift`, directly inside a
    /// target directory that already holds sources; never tests, manifests, nested or protected paths; at most
    /// `maximumNewFiles` per task (including `alreadyCreated`). Anything else stays an invalid target.
    public static func creatableFiles(_ invalid: [String], sources: [String: String], protected: Set<String>,
                                      alreadyCreated: Int = 0) -> [String] {
        let targets = Set(sources.keys.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Sources" ? String(parts[1]) : nil
        })
        // A name the package already declares means the plan guessed the file of an existing type (recorded c2-16:
        // "PayBreakdown.swift" while PayBreakdown lives elsewhere): never create a second, empty file for it.
        let declared = Set(sources.values.flatMap { ContextRelationships.declarations($0).types })
        let allowed = invalid.filter { path in
            let name = String((path.split(separator: "/").last ?? "").dropLast(6))
            guard !declared.contains(name) else { return false }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3 && parts[0] == "Sources" && targets.contains(String(parts[1])) && sources[path] == nil
                && !protected.contains(path) && !parts[1].hasSuffix("Tests")
                && path.range(of: #"^Sources/[A-Za-z0-9_]+/[A-Z][A-Za-z0-9]*\.swift$"#, options: .regularExpression) != nil
        }.sorted()
        return Array(allowed.prefix(max(0, maximumNewFiles - alreadyCreated)))
    }

    public enum Recovery: String, Codable, Sendable, CaseIterable {
        case runtimeRepair
        case contextReplan, compilerRepair, requirementReplan, clauseReplan
        case targetReplan
        /// One re-proposal after an anchor that did not occur exactly once, with deterministic match diagnostics.
        case anchorRepair
        /// One compiler repair of the second attempt's proposal (after a requirement replan or runtime repair). Recorded
        /// c2-12 / c2-10 / c1-20: the first attempt's repair compiled, the replan repeated the same kind of compile error
        /// and the task stopped only because the single compilerRepair was spent. Outside the cap like anchorRepair; the
        /// attempt count (2) still bounds it.
        case replanCompilerRepair
        /// One follow-up after the tests pass when replaced code still exists elsewhere (LeftoverClones). Kept only if it
        /// builds and the tests still pass. Outside the cap like anchorRepair.
        case leftoverRepair
        /// One fix after the tests pass when an independent examiner test fails and a second call confirms the expectation
        /// follows from the request. Kept only if it builds and the tests still pass. Outside the cap like anchorRepair.
        case examinerRepair
        /// One re-proposal after an edit list that was cut off at the output limit (it did not decode; retried with twice
        /// the output budget) or that used append_block on an existing file. Recorded 2026-10-25: c2-10/c2-17 (125B MoE)
        /// and c2-12/c2-15/c3-03 (27B) stopped on a cut-off list; c2-06/c2-15/c3-03 (125B MoE) appended to existing files.
        /// Outside the cap like anchorRepair.
        case formatRepair
        /// One follow-up after the tests pass when functions the change left alone use a name whose code it changed
        /// (UntouchedCallers); only edits inside those functions are kept, and only if it builds and the tests still pass.
        /// Outside the cap like anchorRepair.
        case callerRepair
    }

    /// Clause Coverage Gate: every mandatory clause must be cited by a requirement that
    /// has existing editable targets or an explicit no-change reason. A requirement's own
    /// "complete" label is not enough; nested clauses (e.g. a parenthetical inside a
    /// sentence) must be cited explicitly — citing the enclosing sentence does not cover them.
    public struct ClauseCoverage: Sendable, Equatable {
        public let objectiveClauseCount: Int
        public let mandatory: [String]
        public let covered: [String]
        public let uncovered: [String]
        public let unknownCitations: [String]
        public var complete: Bool { uncovered.isEmpty }
    }

    public static func clauseCoverage(_ plan: RequirementCoveragePlan, clauses: [ObjectiveClause],
                                      sources: [String: String]) -> ClauseCoverage {
        let ids = Set(clauses.map(\.clauseID))
        var covered = Set<String>(), unknown = Set<String>()
        for item in plan.requirements {
            let targets = item.editable_targets.filter { !$0.isEmpty }
            let grounded = (!targets.isEmpty && targets.allSatisfy { sources[$0] != nil })
                || (targets.isEmpty && !(item.no_change_reason ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            for id in item.source_clause_ids {
                if !ids.contains(id) { unknown.insert(id); continue }
                if grounded { covered.insert(id) }
            }
        }
        let mandatory = clauses.filter(\.mandatoryCandidate).map(\.clauseID)
        return .init(objectiveClauseCount: clauses.count, mandatory: mandatory,
                     covered: mandatory.filter(covered.contains), uncovered: mandatory.filter { !covered.contains($0) },
                     unknownCitations: unknown.sorted())
    }

    /// Replan feedback for requirements that have neither editable targets nor a
    /// no-change reason (for example preservation constraints left without a reason).
    public static func incompleteFeedback(_ assessment: Assessment) -> String {
        "These requirements have no editable target and no no_change_reason: \(assessment.uncovered). "
            + "Give each one editable targets from EDITABLE, or — if it only requires keeping something unchanged — "
            + "empty editable_targets and a concrete no_change_reason."
    }

    /// Uncovered-clause replan feedback: objective clauses and the model's own plan only.
    /// Clause replan merge: a replan that covers the missing clauses but drops clauses the previous (ready) plan covered
    /// keeps the previous plan's requirements for exactly those dropped clauses. The merged plan is assessed again by the
    /// caller, so carried-over requirements pass the same target and clause checks as new ones.
    public static func carryingOver(_ plan: RequirementCoveragePlan, previous: RequirementCoveragePlan,
                                    uncovered: [String]) -> RequirementCoveragePlan {
        let missing = Set(uncovered)
        let carried = previous.requirements.filter { !missing.isDisjoint(with: $0.source_clause_ids) && !plan.requirements.contains($0) }
        return RequirementCoveragePlan(requirements: plan.requirements + carried)
    }

    public static func clauseReplanFeedback(_ coverage: ClauseCoverage, clauses: [ObjectiveClause]) -> String {
        let missing = clauses.filter { coverage.uncovered.contains($0.clauseID) }
            .map { "\($0.clauseID): \($0.exactSourceText)" }.joined(separator: " | ")
        return "These mandatory objective clauses are not cited by any requirement that has editable targets or a "
            + "no-change reason: \(missing). Re-plan so every mandatory clause ID appears in source_clause_ids of at "
            + "least one requirement; if a clause needs no code change, cite it in a requirement with empty "
            + "editable_targets and a no_change_reason."
    }

    /// One use per recovery kind and a task-wide cap, so kinds cannot be chained
    /// into an effectively unbounded retry loop. The anchor repair (a re-proposal with deterministic match
    /// diagnostics) is single-use like every kind but does not count toward the cap, so it never takes away a
    /// later compiler, runtime or requirement repair.
    public struct Budget: Sendable, Equatable {
        public static let taskLimit = 2
        static let uncapped: Set<Recovery> = [.anchorRepair, .replanCompilerRepair, .leftoverRepair, .examinerRepair, .formatRepair, .callerRepair]
        public private(set) var used: [Recovery] = []
        public init() {}
        public func allows(_ kind: Recovery) -> Bool {
            !used.contains(kind) && (Self.uncapped.contains(kind) || used.filter { !Self.uncapped.contains($0) }.count < Self.taskLimit)
        }
        public mutating func consume(_ kind: Recovery) -> Bool {
            guard allows(kind) else { return false }
            used.append(kind); return true
        }
    }

    public static func planPrompt(objective: String, editable: [String: String], readOnly: [String: String],
                                  feedback: String? = nil, clauses: [ObjectiveClause] = []) throws -> String {
        func json(_ files: [String: String]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: files, options: [.sortedKeys]), as: UTF8.self)
        }
        return """
        Plan before editing. Split the objective into at most 6 small requirements; keep every field to one short sentence. For each give:
        requirement; source_clause_ids (IDs of the objective clauses below that this requirement comes from); relevant_symbols (identifiers involved); editable_targets (files you will change for it);
        read_only_evidence (files you only read for it); rationale (why these targets satisfy it);
        example (one concrete case of this requirement with every input value and the expected result, in the objective's
        language, e.g. "合計がちょうど5000円の注文 → 送料0円"; a boundary or an exception the objective states when it has one);
        coverage: complete | incomplete | uncertain; no_change_reason when no file needs to change.
        Only EDITABLE files are writable now. If a READ-ONLY file must change to meet a requirement, list it in
        editable_targets; the Harness verifies the code relation before allowing it. Never list files you were not shown.
        no_change_reason is required: use "" when editable_targets is non-empty; for a requirement that only keeps
        something unchanged (for example "do not change the public API"), leave editable_targets empty and explain why
        no file must change.
        Every clause marked mandatory must be cited by at least one requirement. Parenthetical and conditional
        clauses are requirements too, not optional remarks.
        \(feedback.map { "Harness feedback: \($0)\n" } ?? "")Objective: \(objective)
        Objective clauses: \(try clauseJSON(clauses))
        EDITABLE: \(try json(editable))
        READ-ONLY: \(try json(readOnly))
        Return JSON only: {"requirements":[...]}.
        """
    }

    static func clauseJSON(_ clauses: [ObjectiveClause]) throws -> String {
        let rows = clauses.map { ["id": $0.clauseID, "text": $0.exactSourceText, "type": $0.clauseType.rawValue,
                                  "mandatory": $0.mandatoryCandidate] as [String: Any] }
        return String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Harness-driven under-escalation replan: names only requirement text and file
    /// paths already shown to the model.
    public static func contextReplanFeedback(_ assessment: Assessment) -> String {
        """
        Your plan leaves these requirements without an editable target or no-change reason, or relies on symbols \
        owned by READ-ONLY files it did not account for: \(assessment.uncovered). Related READ-ONLY files: \
        \(assessment.relatedEvidence). Re-plan: list a READ-ONLY file in editable_targets only if it must change; \
        otherwise cite it in read_only_evidence and explain.
        """
    }

    /// Verification-guided replan feedback. Deliberately abstract: never includes test
    /// names, assertions, expected values, hidden sources or diagnostics from tests.
    public static func verificationFeedback(previousPlan: RequirementCoveragePlan, diff: String) -> String {
        let plan = (try? String(decoding: JSONEncoder().encode(previousPlan), as: UTF8.self)) ?? "{}"
        return """
        Your previous change compiled, but verification found that some of the original requirements are not met. \
        Re-check every requirement's coverage against the objective. Your previous plan: \(plan) \
        Your previous diff: \(diff)
        """
    }
}
