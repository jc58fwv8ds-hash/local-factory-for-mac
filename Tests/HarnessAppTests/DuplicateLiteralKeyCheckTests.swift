import Testing
@testable import HarnessCore
import Foundation

struct DuplicateLiteralKeyCheckTests {
    @Test func findsARepeatedKeyInOneLiteralOnly() {
        let text = """
        let a: [String: String] = [
            "二頭": "にとう",
            "二頭獣": "にとうじゅう",
            "二頭獣": "にとうじゅう"
        ]
        let b = [
            "二頭": "x"
        ]
        """
        let found = DuplicateLiteralKeyCheck.duplicates(in: text)
        #expect(found.count == 1)
        #expect(found.first?.0 == 4 && found.first?.1 == "二頭獣")
    }
}

struct CompileFailureFilesTests {
    @Test func macroErrorsGoToTheListedFile() {
        let root = URL(fileURLWithPath: "/Users/me/My App")
        let output = """
        macro expansion #expect:1:50: error: main actor-isolated property 'isEnabled' can not be referenced from a nonisolated context
        The following build commands failed:
        \tSwiftCompile normal x86_64 Compiling\\ JapaneseSpeakerTests.swift /Users/me/My\\ App/Tests/JapaneseSpeakerTests.swift (in target 'T')
        \tSwiftCompile normal x86_64 /Users/me/My\\ App/Tests/JapaneseSpeakerTests.swift (in target 'T')
        """
        let found = CompileFailureFiles.diagnostics(output: output, rootURL: root, kind: .xcodeTest)
        #expect(found.map(\.relativePath) == ["Tests/JapaneseSpeakerTests.swift"])
        #expect(found.first?.message.contains("isEnabled") == true)
    }
}

struct FileChangeBudgetTests {
    @Test func growsWithTheFileWithinLimits() {
        #expect(InferenceOutputBudget.fileChange(existingBytes: 0) == InferenceOutputBudget.fileChange)
        #expect(InferenceOutputBudget.fileChange(existingBytes: 12_400) > 10_000)
        #expect(InferenceOutputBudget.fileChange(existingBytes: 1_000_000) == 16_384)
    }
}

struct FailingTestsListTests {
    @Test func theClosingListNamesTheTestedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("failing-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AppTests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "final class JapaneseSpeaker {}".write(to: root.appendingPathComponent("App/JapaneseSpeaker.swift"), atomically: true, encoding: .utf8)
        try "struct JapaneseSpeakerTests {\n    #expect(JapaneseSpeaker.read(\"3本\") == \"さんぼん\")\n}".write(to: root.appendingPathComponent("AppTests/JapaneseSpeakerTests.swift"), atomically: true, encoding: .utf8)
        let output = "llama noise\nFailing tests:\n\tJapaneseSpeakerTests.convertsThreeBonsToSanbon()\n\tJapaneseSpeakerTests.convertsTwentyYearsToHatachi()\n\n** TEST FAILED **"
        let found = TestFailureAnalyzer.diagnostics(output: output, rootURL: root, kind: .xcodeTest)
        #expect(found.map(\.relativePath) == ["App/JapaneseSpeaker.swift"])
        #expect(found.first?.message.contains("convertsThreeBonsToSanbon") == true)
        #expect(found.first?.message.contains("さんぼん") == true)
    }
}
