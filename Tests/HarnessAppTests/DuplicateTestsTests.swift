import Foundation
@testable import HarnessCore
import Testing

struct DuplicateTestsTests {
    @Test func aFailingCopyOfPassingChecksIsFoundAndPlainlyAskedToBeTakenOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dup-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("AppTests"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "actor Translator {}".write(to: root.appendingPathComponent("App/Translator.swift"), atomically: true, encoding: .utf8)
        try "final class Speaker {}".write(to: root.appendingPathComponent("App/Speaker.swift"), atomically: true, encoding: .utf8)
        try """
        @Test func translates() { #expect(t.translate("Hi") == "やあ") }
        @Test func numberReading() {
            #expect(readNumber("3", unit: "本") == "さんぼん")
            #expect(readNumber("1,000", unit: "個") == "せんこ")
        }
        """.write(to: root.appendingPathComponent("AppTests/TranslatorTests.swift"), atomically: true, encoding: .utf8)
        try """
        @Test func three() { #expect(s.preprocess("3本") == "さんぼん") }
        @Test func thousand() { #expect(s.preprocess("1,000個") == "せんこ") }
        """.write(to: root.appendingPathComponent("AppTests/SpeakerTests.swift"), atomically: true, encoding: .utf8)
        let failing = BuildFailureDiagnostic(validationKind: .xcodeTest, relativePath: "App/Translator.swift", line: nil, column: nil,
                                             message: "テスト numberReading が失敗(TranslatorTests.swift): Expectation failed")
        let found = DuplicateTests.find(diagnostics: [failing], rootURL: root)
        let duplicate = try #require(found.first)
        #expect(duplicate.expected == ["さんぼん", "せんこ"])
        #expect(duplicate.otherTestFile == "AppTests/SpeakerTests.swift")
        #expect(duplicate.request.contains("Translator.swift にある同じ処理と、TranslatorTests.swift の numberReading のテストを外し"))
        #expect(duplicate.request.contains("Speaker.swift の処理を使ってください"))
        // When the other file fails too, it is no proof that the work is done there.
        let both = BuildFailureDiagnostic(validationKind: .xcodeTest, relativePath: "App/Speaker.swift", line: nil, column: nil,
                                          message: "テスト three が失敗(SpeakerTests.swift): Expectation failed")
        #expect(DuplicateTests.find(diagnostics: [failing, both], rootURL: root).isEmpty)
    }
}
