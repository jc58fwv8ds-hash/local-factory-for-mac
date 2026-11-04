import Testing
@testable import HarnessExecution

struct SwiftPitfallsTests {
    let book = """
    struct DayBook {
        let zone: TimeZone
        func fileName(_ day: Date) -> String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: day)
        }
        func stamp(_ day: Date) -> String {
            ISO8601DateFormatter().string(from: day)
        }
    }
    """

    @Test func aFormatterWithoutATimeZoneInNewCodeIsFound() {
        let hits = SwiftPitfalls.find(before: [:], after: ["Sources/K/Book.swift": book])
        #expect(hits.map(\.declaration.qualifiedName) == ["DayBook.fileName"])
        #expect(hits.first?.kinds == [.formatterTimeZone])
        #expect(SwiftPitfalls.feedback(hits).contains("DayBook.fileName"))
        let fixed = book.replacingOccurrences(of: "f.dateFormat", with: "f.timeZone = zone\n        f.dateFormat")
        #expect(SwiftPitfalls.find(before: [:], after: ["Sources/K/Book.swift": fixed]).isEmpty)
    }

    @Test func codeTheChangeLeftAloneOrThatHadThePatternIsNotListed() {
        #expect(SwiftPitfalls.find(before: ["Sources/K/Book.swift": book], after: ["Sources/K/Book.swift": book]).isEmpty)
        let changed = book.replacingOccurrences(of: "yyyy-MM-dd", with: "yyyyMMdd")
        #expect(SwiftPitfalls.find(before: ["Sources/K/Book.swift": book], after: ["Sources/K/Book.swift": changed]).isEmpty)
    }

    @Test func uniqueKeysInNewCodeIsFound() {
        let source = "enum M {\n    static func index(_ xs: [String]) -> [String: Int] {\n        Dictionary(uniqueKeysWithValues: xs.enumerated().map { ($1, $0) })\n    }\n}\n"
        #expect(SwiftPitfalls.find(before: [:], after: ["Sources/K/M.swift": source]).first?.kinds == [.uniqueKeys])
    }
}
