import Testing
@testable import HarnessCore

struct ReplaceEditTests {
    let file = """
    struct Screen: View {
        @State private var count = 0

        var body: some View {
            VStack {
                Text("件数")
                if count > 1 {
                    List(items) { Text($0) }
                }
            }
        }
    }
    """

    @Test func aBlockReplacesOnlyItsLines() {
        let answer = """
        <<<<<<< いま
                Text("件数")
                if count > 1 {
        =======
                Text("件数")
                if count > 0 {
        >>>>>>> 変更後
        """
        #expect(ReplaceEdit.apply(answer, to: file) == .changed(file.replacingOccurrences(of: "count > 1", with: "count > 0")))
    }

    @Test func indentationTheModelGotWrongFollowsTheFile() {
        let answer = """
        <<<<<<< いま
        @State private var count = 0
        =======
        @State private var count = 0
        @State private var shown = true
        >>>>>>> 変更後
        """
        guard case let .changed(result) = ReplaceEdit.apply(answer, to: file) else { Issue.record("not placed"); return }
        #expect(result.contains("    @State private var count = 0\n    @State private var shown = true\n"))
    }

    @Test func severalBlocksAndALineTakenOut() {
        let answer = """
        <<<<<<< いま
            @State private var count = 0

        =======
        >>>>>>> 変更後
        <<<<<<< いま
                Text("件数")
        =======
                Text("件数: \\(count)")
        >>>>>>> 変更後
        """
        guard case let .changed(result) = ReplaceEdit.apply(answer, to: file) else { Issue.record("not placed"); return }
        #expect(!result.contains("@State"))
        #expect(result.contains("Text(\"件数: \\(count)\")"))
    }

    @Test func linesThatAreNotInTheFileOrAreThereTwiceAreRefused() {
        let missing = "<<<<<<< いま\n    Text(\"ない行\")\n=======\n    Text(\"x\")\n>>>>>>> 変更後"
        let twice = "<<<<<<< いま\n}\n}\n=======\n}\n// x\n}\n>>>>>>> 変更後"
        if case .failed = ReplaceEdit.apply(missing, to: file) {} else { Issue.record("missing line was placed") }
        if case .failed = ReplaceEdit.apply(twice, to: file) {} else { Issue.record("ambiguous line was placed") }
    }

    @Test func noChangeAndCutOffAnswers() {
        #expect(ReplaceEdit.apply("変更なし", to: file) == .unchanged)
        if case .failed = ReplaceEdit.apply("<<<<<<< いま\n    @State private var count = 0\n=======\n    @State", to: file) {} else {
            Issue.record("a cut-off answer was used")
        }
        if case .failed = ReplaceEdit.apply("{\"content\":\"…\"}", to: file) {} else { Issue.record("JSON was taken as blocks") }
    }
}
