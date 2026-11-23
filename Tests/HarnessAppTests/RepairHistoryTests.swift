import Foundation
@testable import HarnessCore
import Testing

struct RepairHistoryTests {
    @Test func anEarlierDifferentErrorIsGivenWithTheNextRepair() {
        let history = RepairHistory()
        let build = "次のビルドエラーを解消してください。\n対象ファイル: A.swift\n- 行129: has no member 'diacriticInsensitive'\n「diacriticInsensitive」があるのは: NSString.CompareOptions\n変更範囲をこの1ファイルに限定し\n現在のファイル全文:\nlet x = 1"
        let test = "次のビルドエラーを解消してください。\n対象ファイル: A.swift\n- 位置不明: テスト accentInsensitiveMatching が失敗\n現在のファイル全文:\nlet x = 2"
        #expect(history.remind(root: "/p", path: "A.swift", instruction: build) == nil)
        let reminder = history.remind(root: "/p", path: "A.swift", instruction: test)
        #expect(reminder?.contains("NSString.CompareOptions") == true)
        #expect(reminder?.contains("let x = 1") == false)
        #expect(history.remind(root: "/p", path: "B.swift", instruction: test) == nil)
        history.reset(root: "/p")
        #expect(history.remind(root: "/p", path: "A.swift", instruction: test) == nil)
    }
}

struct TestFileInRepairTests {
    @Test func aFailingTestBringsItsWholeTestFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AppTests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "@Test func two() { #expect(read(\"2頭\") == \"にとう\") }\n@Test func three() { #expect(read(\"3本\") == \"さんぼん\") }"
            .write(to: root.appendingPathComponent("AppTests/SpeakerTests.swift"), atomically: true, encoding: .utf8)
        let target = BuildRepairTarget(relativePath: "App/Speaker.swift", diagnostics: [
            BuildFailureDiagnostic(validationKind: .xcodeTest, relativePath: "App/Speaker.swift", line: nil, column: nil,
                                   message: "テスト three が失敗(SpeakerTests.swift): Expectation failed")
        ])
        let text = target.instruction(source: "func read(_ s: String) -> String { s }", projectRoot: root)
        #expect(text.contains("このファイルを確かめるテスト(SpeakerTests.swift)の全文です。いま通らないのは three です。"))
        #expect(text.contains("read(\"2頭\") == \"にとう\""))
    }

    @Test func aResultThatIsTheInputSaysNothingHappened() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AppTests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "@Test func accent() { let r = g.apply(to: \"cafe\"); #expect(r == \"コーヒー\") }"
            .write(to: root.appendingPathComponent("AppTests/GlossaryTests.swift"), atomically: true, encoding: .utf8)
        let target = BuildRepairTarget(relativePath: "App/Glossary.swift", diagnostics: [
            BuildFailureDiagnostic(validationKind: .xcodeTest, relativePath: "App/Glossary.swift", line: nil, column: nil,
                                   message: "テスト accent が失敗(GlossaryTests.swift): Expectation failed: r == \"コーヒー\"(r == \"コーヒー\" → false、r → \"cafe\")")
        ])
        let text = target.instruction(source: "", projectRoot: root)
        #expect(text.contains("「cafe」は、テストが渡した入力そのままです。"))
    }

    @Test func theSameExpectedValueElsewhereIsPointedTo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AppTests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "@Test func n() { #expect(readNumber(\"3\", unit: \"本\") == \"さんぼん\") }"
            .write(to: root.appendingPathComponent("AppTests/TranslatorTests.swift"), atomically: true, encoding: .utf8)
        try "@Test func s() { #expect(speaker.preprocess(\"3本\") == \"さんぼん\") }"
            .write(to: root.appendingPathComponent("AppTests/SpeakerTests.swift"), atomically: true, encoding: .utf8)
        let target = BuildRepairTarget(relativePath: "App/Translator.swift", diagnostics: [
            BuildFailureDiagnostic(validationKind: .xcodeTest, relativePath: "App/Translator.swift", line: nil, column: nil,
                                   message: "テスト n が失敗(TranslatorTests.swift): Expectation failed: readNumber(\"3\", unit: \"本\") == \"さんぼん\"")
        ])
        let text = target.instruction(source: "", projectRoot: root)
        #expect(text.contains("SpeakerTests.swift: @Test func s() { #expect(speaker.preprocess(\"3本\") == \"さんぼん\") }"))
    }

    @Test func theFileTriedLeastIsRepairedFirst() {
        let history = RepairHistory()
        let plan = BuildRepairPlan(targets: [BuildRepairTarget(relativePath: "A.swift", diagnostics: []),
                                             BuildRepairTarget(relativePath: "B.swift", diagnostics: [])], unresolvedErrorCount: 0)
        #expect(history.leastTriedFirst(plan, root: "/p").targets.first?.relativePath == "A.swift")
        #expect(history.leastTriedFirst(plan, root: "/p").targets.first?.relativePath == "B.swift")
        #expect(history.leastTriedFirst(plan, root: "/p").targets.first?.relativePath == "A.swift")
    }

    @Test func theFirstDifferingLetterIsNamed() {
        let text = BuildRepairTarget.firstDifference(in: "テスト yen が失敗(T.swift): Expectation failed: result == \"さんぜんごひゃくえん\"(result == \"さんぜんごひゃくえん\" → false、result → \"さんせんごひゃくえん\")")
        #expect(text?.contains("3 文字目から違います: 「ぜ」であるべき所が「せ」です。") == true)
    }
}
