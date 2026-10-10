import Testing
@testable import HarnessExecution

struct LeftoverClonesTests {
    let before = "func tax(_ l: Line) -> Int {\n    tax = settings.rounding.apply(line.amount * rate.percent, 100 + rate.percent)\n}\n"
    let after = "func tax(_ i: Invoice) -> Int {\n    TaxCalculator.summaries(i).tax\n}\n"

    @Test func replacedExpressionLeftInAnotherFileIsFoundDespiteADifferentLeadIn() {
        let legacy = "let t = cond\n        ? settings.rounding.apply(line.amount * rate.percent, 100 + rate.percent)\n        : 0\n"
        let hits = LeftoverClones.find(changes: ["Sources/A/Journal.swift": (before, after)],
                                       sources: ["Sources/A/Journal.swift": after, "Sources/A/Legacy.swift": legacy])
        #expect(hits == [.init(file: "Sources/A/Legacy.swift", line: 2,
                              text: "? settings.rounding.apply(line.amount * rate.percent, 100 + rate.percent)",
                              replacedIn: "Sources/A/Journal.swift")])
        #expect(LeftoverClones.feedback(hits).contains("Sources/A/Legacy.swift line 2"))
    }

    @Test func shortLinesCommentsAndChangedFilesAreIgnored() {
        let before = "for day in 0..<n {\n// settings.rounding.apply(line.amount * rate.percent, 100 + rate.percent)\n}\n"
        let other = "for day in 0..<n {\n// settings.rounding.apply(line.amount * rate.percent, 100 + rate.percent)\n}\n"
        #expect(LeftoverClones.find(changes: ["Sources/A/X.swift": (before, "")], sources: ["Sources/A/Y.swift": other]).isEmpty)
        // A file the change also edited is not a leftover.
        #expect(LeftoverClones.find(changes: ["Sources/A/J.swift": (self.before, after), "Sources/A/L.swift": (self.before, after)],
                                    sources: ["Sources/A/J.swift": after, "Sources/A/L.swift": after]).isEmpty)
    }
}
