import Foundation

public struct ComputerOperationCheckpoint: Codable, Equatable, Sendable {
    public let instruction: String
    public let plan: ComputerOperationPlan
    public let nextStepIndex: Int
    public let uncertainStepIndex: Int?
    public let startedAt: Date
    public let updatedAt: Date

    public init(
        instruction: String,
        plan: ComputerOperationPlan,
        nextStepIndex: Int,
        uncertainStepIndex: Int? = nil,
        startedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        let boundedNext = min(max(nextStepIndex, 0), plan.steps.count)
        self.instruction = String(instruction.prefix(1_200))
        self.plan = plan
        self.nextStepIndex = boundedNext
        self.uncertainStepIndex = uncertainStepIndex.flatMap {
            plan.steps.indices.contains($0) ? $0 : nil
        }
        self.startedAt = min(startedAt, updatedAt)
        self.updatedAt = max(startedAt, updatedAt)
    }

    public var requiresUserDecision: Bool {
        uncertainStepIndex != nil
    }
}
