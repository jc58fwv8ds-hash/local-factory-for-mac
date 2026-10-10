import Foundation

public enum VerificationKind: String, Codable, Sendable, CaseIterable {
    case build, testExecution, unit, integration, ui, visual, acceptance, heldOut
}

public struct VerificationRequirement: Codable, Equatable, Sendable {
    public let id: UUID
    public let criterion: String
    public let kind: VerificationKind

    public init(id: UUID = UUID(), criterion: String, kind: VerificationKind) {
        self.id = id
        self.criterion = criterion
        self.kind = kind
    }
}

public struct KernelStep: Codable, Equatable, Sendable {
    public let id: UUID
    public let instruction: String

    public init(id: UUID = UUID(), instruction: String) {
        self.id = id
        self.instruction = instruction
    }
}

/// The first migration uses a sequential plan. Dependencies and role routing come later.
public struct KernelPlan: Codable, Equatable, Sendable {
    public let userRequest: String
    public let modelIdentifier: String
    public let steps: [KernelStep]
    public let requirements: [VerificationRequirement]

    public init(
        userRequest: String, modelIdentifier: String,
        steps: [KernelStep], requirements: [VerificationRequirement]
    ) {
        self.userRequest = userRequest
        self.modelIdentifier = modelIdentifier
        self.steps = steps
        self.requirements = requirements
    }

    public var isValid: Bool {
        !userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !steps.isEmpty && steps.count <= 100
            && !requirements.isEmpty && requirements.count <= 100
            && Set(steps.map(\.id)).count == steps.count
            && Set(requirements.map(\.id)).count == requirements.count
            && steps.allSatisfy { !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && requirements.allSatisfy { !$0.criterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public struct KernelEvidence: Codable, Equatable, Sendable {
    public let requirementID: UUID
    public let revision: Int
    public let passed: Bool
    /// Reference to an independently produced report, not model prose.
    public let reportReference: String

    public init(requirementID: UUID, revision: Int, passed: Bool, reportReference: String) {
        self.requirementID = requirementID
        self.revision = revision
        self.passed = passed
        self.reportReference = reportReference
    }
}
