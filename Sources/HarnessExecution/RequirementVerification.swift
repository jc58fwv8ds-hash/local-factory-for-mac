import Foundation
import HarnessCore

/// Post-Implementation Requirement Gate. Build/test success never finalizes a task: an
/// independent verifier (never the builder) checks the original objective's clauses and the
/// accepted requirement plan against the final production diff/code and reports, per item,
/// SATISFIED / VIOLATED / UNCERTAIN. Any violation fails the task; uncertainty is fail-closed.
/// The request carries no test sources or expected values.
public enum RequirementVerification {
    public enum Verdict: String, Codable, Sendable { case SATISFIED, VIOLATED, UNCERTAIN }
    public enum FindingKind: String, Codable, Sendable { case REQUIREMENT_VIOLATION, QUALITY_WARNING }
    public enum Outcome: String, Codable, Sendable {
        case REQUIREMENTS_SATISFIED, REQUIREMENT_VIOLATION, REQUIREMENT_UNCERTAIN, INVALID_REPORT
    }
    public static let pendingResult = "REQUIREMENT_VERIFICATION_PENDING"
    public static let falseSuccessResult = "VERIFICATION_FALSE_SUCCESS"
    public static let uncertainResult = "REQUIREMENT_UNCERTAIN"
    public static let maximumCodeCharacters = 12_000
    static let independentRoles: Set<String> = ["independent_reviewer", "verifier"]

    public struct Item: Codable, Equatable, Sendable {
        public let id: String
        public let text: String
        public init(id: String, text: String) { self.id = id; self.text = text }
    }

    public struct Request: Codable, Equatable, Sendable {
        public let taskID: String
        public let objective: String
        public let clauses: [Item]
        public let requirements: [Item]
        public let productionDiff: String
        public let finalCode: [String: String]
        public let builderModel: String
        public var requiredIDs: [String] { clauses.map(\.id) + requirements.map(\.id) }
    }

    public struct ItemVerdict: Codable, Equatable, Sendable {
        public let id: String
        public let verdict: Verdict
        public let evidence: String
        public init(id: String, verdict: Verdict, evidence: String) { self.id = id; self.verdict = verdict; self.evidence = evidence }
    }

    public struct Finding: Codable, Equatable, Sendable {
        public let kind: FindingKind
        public let text: String
        public init(kind: FindingKind, text: String) { self.kind = kind; self.text = text }
    }

    public struct Verifier: Codable, Equatable, Sendable {
        public let role: String
        public let identity: String
        public init(role: String, identity: String) { self.role = role; self.identity = identity }
    }

    public struct Report: Codable, Equatable, Sendable {
        public let taskID: String
        public let verifier: Verifier
        public let items: [ItemVerdict]
        public let findings: [Finding]
        public init(taskID: String, verifier: Verifier, items: [ItemVerdict], findings: [Finding]) {
            self.taskID = taskID; self.verifier = verifier; self.items = items; self.findings = findings
        }
    }

    public struct Decision: Codable, Equatable, Sendable {
        public let outcome: Outcome
        public let reasons: [String]
        public let qualityWarnings: [String]
    }

    /// Mandatory objective clauses plus the accepted plan's requirements, and the production
    /// changes only (tests and protected files are never included).
    public static func request(taskID: String, objective: String, clauses: [ObjectiveClause],
                               plan: RequirementCoveragePlan, proposals: [FileChangeProposal],
                               protected: Set<String>, builderModel: String) -> Request {
        let production = proposals.filter { !protected.contains($0.relativePath) && !$0.relativePath.contains("Tests/") }
        var budget = maximumCodeCharacters
        var code: [String: String] = [:]
        for proposal in production.sorted(by: { $0.relativePath < $1.relativePath }) where budget > 0 {
            let text = String(proposal.proposedContent.prefix(budget))
            code[proposal.relativePath] = text
            budget -= text.count
        }
        return Request(taskID: taskID, objective: objective,
            clauses: clauses.filter(\.mandatoryCandidate).map { Item(id: $0.clauseID, text: $0.exactSourceText) },
            requirements: plan.requirements.enumerated().map { Item(id: "R\($0.offset + 1)", text: $0.element.requirement) },
            productionDiff: CompilerRepair.renderDiff(production), finalCode: code, builderModel: builderModel)
    }

    /// Deterministic gate over an independent report. Tests passing is not an input.
    public static func decide(_ report: Report, for request: Request) -> Decision {
        var invalid: [String] = []
        let role = report.verifier.role.trimmingCharacters(in: .whitespaces)
        let identity = report.verifier.identity.trimmingCharacters(in: .whitespaces)
        if !independentRoles.contains(role) { invalid.append("verifier role '\(role)' is not independent") }
        if identity.isEmpty || identity == request.builderModel || role == "builder" {
            invalid.append("self-certification: verifier identity must differ from the builder")
        }
        if report.taskID != request.taskID { invalid.append("report task \(report.taskID) ≠ request \(request.taskID)") }
        let ids = report.items.map(\.id)
        let required = Set(request.requiredIDs)
        let missing = required.subtracting(ids).sorted()
        let unknown = Set(ids).subtracting(required).sorted()
        let duplicated = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 }).sorted()
        if !missing.isEmpty { invalid.append("missing verdicts: \(missing.joined(separator: ", "))") }
        if !unknown.isEmpty { invalid.append("unknown items: \(unknown.joined(separator: ", "))") }
        if !duplicated.isEmpty { invalid.append("duplicate items: \(duplicated.joined(separator: ", "))") }
        if report.items.contains(where: { $0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            invalid.append("every verdict needs evidence")
        }
        let warnings = report.findings.filter { $0.kind == .QUALITY_WARNING }.map(\.text)
        guard invalid.isEmpty else { return .init(outcome: .INVALID_REPORT, reasons: invalid, qualityWarnings: warnings) }
        let violated = report.items.filter { $0.verdict == .VIOLATED }.map { "\($0.id): \($0.evidence)" }
            + report.findings.filter { $0.kind == .REQUIREMENT_VIOLATION }.map { "finding: \($0.text)" }
        if !violated.isEmpty { return .init(outcome: .REQUIREMENT_VIOLATION, reasons: violated, qualityWarnings: warnings) }
        let uncertain = report.items.filter { $0.verdict == .UNCERTAIN }.map { "\($0.id): \($0.evidence)" }
        if !uncertain.isEmpty { return .init(outcome: .REQUIREMENT_UNCERTAIN, reasons: uncertain, qualityWarnings: warnings) }
        return .init(outcome: .REQUIREMENTS_SATISFIED, reasons: [], qualityWarnings: warnings)
    }

    /// Final harness result. Only a fully satisfied report releases the tests-passed result.
    public static func finalResult(testsPassedResult: String, decision: Decision) -> String {
        switch decision.outcome {
        case .REQUIREMENTS_SATISFIED: testsPassedResult
        case .REQUIREMENT_VIOLATION: falseSuccessResult
        case .REQUIREMENT_UNCERTAIN: uncertainResult
        case .INVALID_REPORT: pendingResult
        }
    }
}
