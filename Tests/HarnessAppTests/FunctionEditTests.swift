import Testing
@testable import HarnessCore

struct FunctionEditTests {
    let file = """
    import Foundation

    final class Controller {
        private var queue: [String] = []

        func handlePartial(_ text: String) {
            if text.count > 20 { handleTranscript(text) }
        }

        /// Sends one piece to translation.
        func handleTranscript(_ text: String) {
            queue.append(text)
        }
    }

    struct Other {
        func handlePartial() {}
    }
    """

    @Test func replacesTheNamedFunctionAndKeepsTheRest() throws {
        let answer = """
        func handlePartial(_ text: String) {
            partialText = text
        }
        """
        let result = try #require(FunctionEdit.splice(answer, into: file))
        #expect(result.contains("        partialText = text"))
        #expect(!result.contains("if text.count > 20"))
        #expect(result.contains("queue.append(text)"))
        #expect(result.contains("struct Other {\n    func handlePartial() {}"))
    }

    @Test func addsNewDeclarationsToTheSameType() throws {
        let answer = """
        func handleTranscript(_ text: String) {
            guard text != lastSent else { return }
            lastSent = text
            queue.append(text)
        }

        private var lastSent = ""
        """
        let result = try #require(FunctionEdit.splice(answer, into: file))
        let classEnd = try #require(result.range(of: "\n}\n\nstruct Other"))
        let added = try #require(result.range(of: "    private var lastSent = \"\""))
        #expect(added.lowerBound < classEnd.lowerBound)
        #expect(result.contains("        guard text != lastSent else { return }"))
    }

    @Test func aWholeFileIsTakenAsItIsAndNothingIsNil() {
        let whole = file.replacingOccurrences(of: "queue.append(text)", with: "queue.insert(text, at: 0)")
        #expect(FunctionEdit.splice(whole, into: file) == whole)
        #expect(FunctionEdit.splice("", into: file) == nil)
        #expect(FunctionEdit.applies(to: String(repeating: "a", count: FunctionEdit.minimumCharacters)))
    }

    @Test func removesAndReplacesProperties() throws {
        let removed = try #require(FunctionEdit.splice("// 削除: queue", into: file))
        #expect(!removed.contains("private var queue"))
        #expect(removed.contains("func handleTranscript"))
        let replaced = try #require(FunctionEdit.splice("private var queue: [String] = [\"start\"]", into: file))
        #expect(replaced.contains("    private var queue: [String] = [\"start\"]"))
        #expect(!replaced.contains("private var queue: [String] = []"))
    }

    @Test func anAnswerWithItsOwnIndentationTakesTheFilesOwn() throws {
        let answer = "    func handleTranscript(_ text: String) {\n                guard !text.isEmpty else { return }\n                queue.append(text)\n            }"
        let result = try #require(FunctionEdit.splice(answer, into: file))
        #expect(result.contains("\n    func handleTranscript(_ text: String) {\n        guard !text.isEmpty else { return }\n        queue.append(text)\n    }"))
    }
}
