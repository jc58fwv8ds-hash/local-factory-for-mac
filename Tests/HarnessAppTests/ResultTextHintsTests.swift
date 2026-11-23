import Testing
@testable import HarnessCore

struct ResultTextHintsTests {
    @Test func findsTheDebugTextOfAResultAndAnEscapedInterpolation() {
        let listener = "for try await result in transcriber.results {\n    let text = result.description\n}\n// SpeechTranscriber"
        #expect(NotWorkingHints.wrongText([("L.swift", listener)]).first?.contains(NotWorkingHints.debugTextMark) == true)
        let pattern = "let pattern = \"\\\\b\\\\(escapedTerm)\\\\b\""
        #expect(NotWorkingHints.wrongText([("C.swift", pattern)]).first?.contains(NotWorkingHints.escapedInterpolationMark) == true)
    }

    @Test func leavesTheRightFormsAlone() {
        let good = "// SpeechTranscriber\nlet text = String(result.text.characters)\nlet pattern = \"\\\\b\" + escapedTerm + \"\\\\b\"\nlet message = \"value: \\(count)\""
        #expect(NotWorkingHints.wrongText([("A.swift", good)]).isEmpty)
    }
}
