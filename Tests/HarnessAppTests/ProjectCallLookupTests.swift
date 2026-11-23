import Foundation
import HarnessCore
import Testing

struct ProjectCallLookupTests {
    // 2026-11-16: 14Translate's test called translate with its arguments in the wrong order six times.
    @Test func theCalledFunctionsDeclarationIsShownForAnArgumentError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("call-lookup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        try "actor PlamoTranslator {\n    func translate(_ text: String, glossary: [SlangGlossary], sourceLang: String) -> [String] {\n        []\n    }\n}\n"
            .write(to: root.appendingPathComponent("App/PlamoTranslator.swift"), atomically: true, encoding: .utf8)
        let line = #"        let result = try await translator.translate("Good morning.", sourceLang: "en", glossary: [])"#
        let found = ProjectCallLookup.declarations(messages: ["argument 'glossary' must precede argument 'sourceLang'"],
                                                   lines: [line], projectRoot: root)
        #expect(found == ["PlamoTranslator.swift: func translate(_ text: String, glossary: [SlangGlossary], sourceLang: String) -> [String]"])
        #expect(ProjectCallLookup.declarations(messages: ["cannot find 'x' in scope"], lines: [line], projectRoot: root).isEmpty)
        let target = BuildRepairTarget(relativePath: "Tests/PlamoTranslatorTests.swift", diagnostics: [
            BuildFailureDiagnostic(validationKind: .test, relativePath: "Tests/PlamoTranslatorTests.swift", line: 1, column: 1,
                                   message: "argument 'glossary' must precede argument 'sourceLang'")])
        #expect(target.instruction(source: line, projectRoot: root).contains("glossary: [SlangGlossary], sourceLang: String"))
        try "final class SlangGlossaryStore: ObservableObject {\n    init() {\n    }\n    init(from decoder: Decoder) throws {\n    }\n}\n"
            .write(to: root.appendingPathComponent("App/SlangGlossary.swift"), atomically: true, encoding: .utf8)
        let made = ProjectCallLookup.declarations(messages: ["incorrect argument label in call (have 'entries:', expected 'from:')"],
                                                  lines: ["        let store = SlangGlossaryStore(entries: [(\"bet\", \"了解\")])"],
                                                  projectRoot: root)
        #expect(made == ["SlangGlossary.swift: SlangGlossaryStore の init()", "SlangGlossary.swift: SlangGlossaryStore の init(from decoder: Decoder) throws"])
        try? FileManager.default.removeItem(at: root)
    }
}

struct ArtifactPlanDuplicateTests {
    @Test func aFileNamedTwiceBecomesOneStepWithBothInstructions() throws {
        let response = #"{"files":[{"path":"App/PlamoTranslator.swift","instruction":"glossary を input の前に"},{"path":"App/Screen.swift","instruction":"画面"},{"path":"App/PlamoTranslator.swift","instruction":"input に lang を付ける"}]}"#
        let plan = try ArtifactPlanResponseParser.plan(from: response, instruction: "直して",
                                                       existingPaths: ["App/PlamoTranslator.swift", "App/Screen.swift"])
        #expect(plan.targets.count == 2)
        #expect(plan.targets[0].instruction == "glossary を input の前に\ninput に lang を付ける")
    }
}
