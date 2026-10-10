import Foundation

public enum InferenceOutputBudget {
    public static let conversation = 3_072
    public static let artifactPlan = 4_096
    public static let fileChange = 4_096
    public static let computerPlan = 1_024
    public static let computerSummary = 768
    public static let termExplanation = 384
    public static let replySuggestions = 1_024
    public static let workPlanReplan = 2_048

    static let minimum = 256
    static let maximum = 4_096

    public static func bounded(_ requestedTokens: Int) -> Int {
        min(max(requestedTokens, minimum), maximum)
    }
}
