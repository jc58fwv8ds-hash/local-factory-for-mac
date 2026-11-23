import Foundation
import Testing
@testable import HarnessCore

struct TypeCheckTimeoutHintsTests {
    @Test func namesTheModifierAndMemberThatDoNotExist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        final class TranslationController {
            var lastTranslation: String = ""
            var history: [String] = []
        }
        """.write(to: root.appendingPathComponent("TranslationController.swift"), atomically: true, encoding: .utf8)
        let screen = """
        struct TranslationScreen: View {
            var controller: TranslationController
            var body: some View {
                ScrollView {
                    ForEach(controller.translations, id: \\.id) { t in
                        Text(t.text).font(.title)
                    }
                }
                .scrollToID(nil, anchor: .bottom)
            }
        }
        """
        try screen.write(to: root.appendingPathComponent("TranslationScreen.swift"), atomically: true, encoding: .utf8)
        let hint = try #require(TypeCheckTimeoutHints.hint(
            messages: ["the compiler is unable to type-check this expression in reasonable time"],
            lines: screen.components(separatedBy: "\n"), errorLines: [4], projectRoot: root,
            sdkDeclares: { ["font", "title"].contains($0) }))
        #expect(hint.contains(".scrollToID(…)"))
        #expect(hint.contains("controller.translations: TranslationController に translations はありません"))
        #expect(hint.contains("history"))
        #expect(hint.contains("proxy.scrollTo"))
        #expect(!hint.contains(".font("))
    }

    @Test func silentForOtherErrors() {
        #expect(TypeCheckTimeoutHints.hint(messages: ["cannot find 'x' in scope"], lines: [], errorLines: [],
                                           projectRoot: URL(fileURLWithPath: "/")) == nil)
    }
}
