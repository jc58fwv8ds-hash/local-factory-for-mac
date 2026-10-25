import Testing
@testable import HarnessExecution

struct UntouchedCallersTests {
    let fare = """
    struct FareCalculator {
        static func cap(for card: String) -> Int {
            card == "child" ? 300 : 600
        }
        func total(_ card: String) -> Int {
            Self.cap(for: card) * 2 // "{" in a comment
        }
    }
    struct CapStatus {
        var remaining: Int {
            FareCalculator.cap(for: "adult") - 100
        }
        func label() -> String { "残り" }
    }
    """

    @Test func functionsLeftAloneThatUseAChangedNameAreListed() {
        let after = fare.replacingOccurrences(of: "300 : 600", with: "250 : 600")
        let hits = UntouchedCallers.find(before: ["Sources/K/Fare.swift": fare], after: ["Sources/K/Fare.swift": after])
        #expect(hits.map(\.declaration.qualifiedName) == ["FareCalculator.total", "CapStatus.remaining"])
        #expect(hits.allSatisfy { $0.uses == ["cap"] })
        #expect(UntouchedCallers.find(before: ["Sources/K/Fare.swift": fare], after: ["Sources/K/Fare.swift": fare]).isEmpty)
    }

    @Test func onlyEditsInsideAListedFunctionAreKept() {
        let after = fare.replacingOccurrences(of: "300 : 600", with: "250 : 600")
        let hits = UntouchedCallers.find(before: ["Sources/K/Fare.swift": fare], after: ["Sources/K/Fare.swift": after])
        #expect(UntouchedCallers.insideListed("FareCalculator.cap(for: \"adult\") - 100", file: "Sources/K/Fare.swift", hits: hits))
        #expect(!UntouchedCallers.insideListed("card == \"child\" ? 250 : 600", file: "Sources/K/Fare.swift", hits: hits))
        #expect(!UntouchedCallers.insideListed("", file: "Sources/K/Fare.swift", hits: hits))
        #expect(UntouchedCallers.feedback(hits).contains("CapStatus.remaining"))
    }
}
