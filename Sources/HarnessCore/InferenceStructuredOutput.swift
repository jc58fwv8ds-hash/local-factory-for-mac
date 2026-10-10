import Foundation

public enum InferenceStructuredOutput: String, Equatable, Sendable {
    case localRequirementReview
    case structuredEditBatch
    case fileContent
    case artifactPlan
    case computerPlan
    case replySuggestions
    case workPlanReplan
    case repairReview
    case structuredEdit
    case coveragePlan
    case targetDiscoveryRequest
    case targetNomination
}

enum InferenceJSONSchema: Encodable {
    case localRequirementReview
    case structuredEditBatch
    case fileContent
    case artifactPlan
    case computerPlan
    case replySuggestions
    case workPlanReplan
    case repairReview
    case structuredEdit
    case coveragePlan
    case targetDiscoveryRequest
    case targetNomination

    init(_ output: InferenceStructuredOutput) {
        self = switch output {
        case .localRequirementReview: .localRequirementReview
        case .structuredEditBatch: .structuredEditBatch
        case .fileContent: .fileContent
        case .artifactPlan: .artifactPlan
        case .computerPlan: .computerPlan
        case .replySuggestions: .replySuggestions
        case .workPlanReplan: .workPlanReplan
        case .repairReview: .repairReview
        case .structuredEdit: .structuredEdit
        case .coveragePlan: .coveragePlan
        case .targetDiscoveryRequest: .targetDiscoveryRequest
        case .targetNomination: .targetNomination
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .localRequirementReview:
            try LocalRequirementReviewSchema().encode(to: encoder)
        case .structuredEditBatch:
            try EditBatchSchema().encode(to: encoder)
        case .fileContent:
            try FileContentSchema().encode(to: encoder)
        case .artifactPlan:
            try ArtifactPlanSchema().encode(to: encoder)
        case .computerPlan:
            try ComputerPlanSchema().encode(to: encoder)
        case .replySuggestions:
            try ReplySuggestionsSchema().encode(to: encoder)
        case .workPlanReplan:
            try WorkPlanReplanSchema().encode(to: encoder)
        case .repairReview:
            try RepairReviewSchema().encode(to: encoder)
        case .structuredEdit:
            try StructuredEditSchema().encode(to: encoder)
        case .coveragePlan:
            try CoveragePlanSchema().encode(to: encoder)
        case .targetDiscoveryRequest:
            try TargetDiscoveryRequestSchema().encode(to: encoder)
        case .targetNomination:
            try TargetNominationSchema().encode(to: encoder)
        }
    }
}

private struct TargetDiscoveryRequestSchema: Encodable {
    struct Text: Encodable {
        let type = "string"
        let minLength = 1
        let maxLength: Int
        var pattern: String? = nil
    }
    struct Terms: Encodable {
        let type = "array"
        let minItems = 1
        let maxItems = TargetDiscoveryRequest.maximumTerms
        let items = Text(maxLength: TargetDiscoveryRequest.maximumTermLength, pattern: TargetDiscoveryRequest.termPattern)
    }
    struct Properties: Encodable {
        let search_terms = Terms()
        let expected_symbol_kind = Text(maxLength: TargetDiscoveryRequest.maximumTermLength)
        let expected_behavior = Text(maxLength: TargetDiscoveryRequest.maximumDescriptionLength)
        let why_needed = Text(maxLength: TargetDiscoveryRequest.maximumDescriptionLength)
    }
    let type = "object"
    let properties = Properties()
    let required = ["search_terms", "expected_symbol_kind", "expected_behavior", "why_needed"]
    let additionalProperties = false
}

private struct StructuredEditSchema: Encodable {
    struct Operation: Encodable {
        let type = "string"
        let `enum` = ["replace_exact"]
    }
    struct LineCount: Encodable {
        let type = "integer"
        let minimum = 1
        let maximum = 1
    }
    struct Properties: Encodable {
        let operation = Operation()
        let file = StringSchema()
        let expected_old_text = StringSchema()
        let new_text = StringSchema()
        let max_changed_lines = LineCount()
    }
    let type = "object"
    let properties = Properties()
    let required = ["operation", "file", "expected_old_text", "new_text", "max_changed_lines"]
    let additionalProperties = false
}

private struct RepairReviewSchema: Encodable {
    struct Verdict: Encodable {
        let type = "string"
        let `enum` = ["pass", "changesRequired", "insufficientEvidence"]
    }
    struct Properties: Encodable {
        let sourceDigest = StringSchema()
        let correctness = Verdict()
        let maintainability = Verdict()
        let explanation = StringSchema()
    }
    let type = "object"
    let properties = Properties()
    let required = ["sourceDigest", "correctness", "maintainability", "explanation"]
    let additionalProperties = false
}

private struct StringSchema: Encodable {
    let type = "string"
}

private struct StringArraySchema: Encodable {
    let type = "array"
    let items = StringSchema()
    let maxItems: Int
}

private struct FileContentSchema: Encodable {
    struct Properties: Encodable {
        let content = StringSchema()
    }

    let type = "object"
    let properties = Properties()
    let required = ["content"]
    let additionalProperties = false
}

private struct ArtifactPlanSchema: Encodable {
    struct Properties: Encodable {
        let files = ArtifactFilesSchema()
    }

    let type = "object"
    let properties = Properties()
    let required = ["files"]
    let additionalProperties = false
}

private struct ArtifactFilesSchema: Encodable {
    let type = "array"
    let items = ArtifactFileSchema()
    let minItems = 2
    let maxItems = ArtifactCreationPlan.maximumTargets
}

private struct ArtifactFileSchema: Encodable {
    struct Properties: Encodable {
        let path = StringSchema()
        let instruction = StringSchema()
    }

    let type = "object"
    let properties = Properties()
    let required = ["path", "instruction"]
    let additionalProperties = false
}

private struct WorkPlanReplanSchema: Encodable {
    struct Properties: Encodable {
        let summary = StringSchema()
        let uncertainties = StringArraySchema(
            maxItems: WorkPlanReplanProposal.maximumUncertainties
        )
        let items = WorkPlanReplanItemsSchema()
    }

    let type = "object"
    let properties = Properties()
    let required = ["summary", "uncertainties", "items"]
    let additionalProperties = false
}

private struct WorkPlanReplanItemsSchema: Encodable {
    let type = "array"
    let items = WorkPlanReplanItemSchema()
    let minItems = 1
    let maxItems = WorkPlanReplanContext.maximumExistingItems
}

private struct WorkPlanReplanItemSchema: Encodable {
    struct Properties: Encodable {
        let reference = NullableStringSchema()
        let title = StringSchema()
        let detail = StringSchema()
    }

    let type = "object"
    let properties = Properties()
    let required = ["reference", "title", "detail"]
    let additionalProperties = false
}

private struct ComputerPlanSchema: Encodable {
    struct Properties: Encodable {
        let summary = StringSchema()
        let steps = ComputerStepsSchema()
    }

    let type = "object"
    let properties = Properties()
    let required = ["summary", "steps"]
    let additionalProperties = false
}

private struct ComputerStepsSchema: Encodable {
    let type = "array"
    let items = ComputerStepSchema()
    let minItems = 1
    let maxItems = ComputerOperationPlan.maximumSteps
}

private struct ComputerStepSchema: Encodable {
    struct Properties: Encodable {
        let kind = ComputerKindSchema()
        let query = NullableStringSchema()
        let application = NullableStringSchema()
        let element = NullableStringSchema()
        let reason = StringSchema()
    }

    let type = "object"
    let properties = Properties()
    let required = ["kind", "query", "application", "element", "reason"]
    let additionalProperties = false
}

private struct ComputerKindSchema: Encodable {
    let type = "string"
    let `enum` = ComputerOperationKind.allCases.map(\.rawValue)
}

private struct NullableStringSchema: Encodable {
    let type = ["string", "null"]
}
