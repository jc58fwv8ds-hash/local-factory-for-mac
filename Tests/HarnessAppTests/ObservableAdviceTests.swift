import Testing
@testable import HarnessCore

struct ObservableAdviceTests {
    @Test func aPlainClassUnderObservedObjectGetsAWayOut() {
        let lines = BuildErrorAdvice.lines(for: ["generic struct 'ObservedObject' requires that 'TranscriptStore' conform to 'ObservableObject'"])
        #expect(lines.first?.contains("@State private var") == true)
        #expect(lines.first?.contains("このエラーは消えません") == true)
    }
}

struct CapturedVarAdviceTests {
    @Test func aCapturedVarGetsABox() {
        let lines = BuildErrorAdvice.lines(for: ["mutation of captured var 'result' in concurrently-executing code [#SendableClosureCaptures]"])
        #expect(lines.first?.contains("@unchecked Sendable") == true)
    }
}
