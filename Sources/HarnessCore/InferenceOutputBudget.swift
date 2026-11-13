import Foundation

public enum InferenceOutputBudget {
    public static let conversation = 3_072
    public static let artifactPlan = 4_096
    public static let fileChange = 4_096
    /// A file written whole comes back at least as long as it is: the budget grows with it (2026-11-12: a 12 KB file with a
    /// reading table to add was cut off at 4,096 tokens twice, and the answer could not be read). About one token per
    /// two UTF-8 bytes of Japanese-and-Swift text, times 1.6 for what is added, plus room; at most 16,384.
    public static func fileChange(existingBytes: Int) -> Int {
        min(16_384, max(fileChange, Int(Double(existingBytes) / 2 * 1.6) + 1_536))
    }
    public static let computerPlan = 1_024
    public static let computerSummary = 768
    public static let termExplanation = 384
    public static let replySuggestions = 1_024
    public static let workPlanReplan = 2_048

    static let minimum = 256
    /// The largest any request may ask for: a whole file written back (2026-11-13: every request was cut to 4,096 here, so the
    /// budget of `fileChange(existingBytes:)` never reached the model, and 14Translate's 14–19 KB files came back cut off —
    /// all four of the person's requests failed with 「安全な形式として読み取れませんでした」).
    public static let maximum = 16_384

    public static func bounded(_ requestedTokens: Int) -> Int {
        min(max(requestedTokens, minimum), maximum)
    }
}
