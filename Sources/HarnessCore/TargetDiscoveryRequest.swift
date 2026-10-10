import Foundation

public struct TargetDiscoveryRequest: Codable, Equatable, Sendable {
    public static let maximumTerms = 8
    public static let maximumTermLength = 80
    public static let maximumDescriptionLength = 300
    public static let termPattern = #"^(?![\s\S]*[\\/])(?![\s\S]*\.(?:[sS][wW][iI][fF][tT]|[mM][mM]?|[hH])$)[\s\S]*\S[\s\S]*$"#
    public static let promptContract = "search_terms: 1–8 strings, each 1–80 Unicode code points, at least one non-whitespace character; no slash, backslash or .swift/.m/.mm/.h filename suffix (case insensitive). expected_symbol_kind: 1–80 code points. expected_behavior and why_needed: each 1–300 code points."
    public let search_terms: [String]
    public let expected_symbol_kind: String
    public let expected_behavior: String
    public let why_needed: String

    public init(search_terms: [String], expected_symbol_kind: String,
                expected_behavior: String, why_needed: String) {
        self.search_terms = search_terms
        self.expected_symbol_kind = expected_symbol_kind
        self.expected_behavior = expected_behavior
        self.why_needed = why_needed
    }

    public func validated() throws -> Self {
        guard !search_terms.isEmpty, search_terms.count <= Self.maximumTerms,
              search_terms.allSatisfy(Self.isAllowedSearchTerm),
              !expected_symbol_kind.isEmpty, expected_symbol_kind.unicodeScalars.count <= Self.maximumTermLength,
              !expected_behavior.isEmpty, expected_behavior.unicodeScalars.count <= Self.maximumDescriptionLength,
              !why_needed.isEmpty, why_needed.unicodeScalars.count <= Self.maximumDescriptionLength else { throw InferenceError.invalidResponse }
        return self
    }

    private static func isAllowedSearchTerm(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= maximumTermLength
            && value.range(of: termPattern, options: .regularExpression) != nil
    }
}
