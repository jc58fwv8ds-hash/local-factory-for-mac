import Testing
@testable import HarnessCore

struct SubtitleHintsTests {
    @Test func findsCommaSplittingAndALatestOnlyScreen() {
        let translator = """
        final class Translator {
            func translate(_ text: String) { for piece in splitText(text) { model.generate(piece) } }
            private func splitText(_ text: String) -> [String] {
                let separators: [Character] = ["。", ".", "?", "、", ","]
                return []
            }
        }
        """
        let controller = """
        final class Controller {
            var history: [String] = []
            var lastTranslation = ""
        }
        """
        let screen = """
        struct Screen: View {
            var body: some View {
                Text(controller.lastTranslation)
            }
        }
        """
        let hints = NotWorkingHints.subtitleGaps([("T.swift", translator), ("C.swift", controller), ("S.swift", screen)])
        #expect(hints.contains { $0.contains(NotWorkingHints.commaSplitMark) })
        #expect(hints.contains { $0.contains(NotWorkingHints.latestOnlyMark) })
    }

    @Test func sentenceEndsOnlyAndAListedScreenAreFine() {
        let translator = """
        final class Translator {
            func translate(_ text: String) { model.generate(text) }
            private func splitText(_ text: String) -> [String] {
                let separators: [Character] = ["。", ".", "?"]
                return []
            }
        }
        """
        let screen = """
        struct Screen: View {
            var body: some View {
                ForEach(controller.history) { Text($0) }
                Text(controller.lastTranslation)
            }
        }
        """
        #expect(NotWorkingHints.subtitleGaps([("T.swift", translator), ("S.swift", screen)]).isEmpty)
    }

    @Test func findsNewestFirstListScrolledToTheOldest() {
        let controller = ("TranslationController.swift", "final class C {\n    var history: [Pair] = []\n    func add(_ p: Pair) {\n        history.insert(p, at: 0)\n    }\n}")
        let screen = ("TranslationScreen.swift", """
        struct S: View {
            var body: some View {
                if controller.history.count > 1 {
                    ScrollViewReader { proxy in
                        ForEach(controller.history) { Text($0.translation) }
                    }
                }
            }
            func go(_ proxy: ScrollViewProxy) { if let last = controller.history.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
        """)
        let hints = NotWorkingHints.subtitleGaps([controller, screen])
        #expect(hints.contains { $0.contains(NotWorkingHints.newestOnTopMark) })
        #expect(hints.contains { $0.contains("count > 1") })
        #expect(NotWorkingHints.subtitleGaps([("A.swift", "final class C { var history: [P] = []; func add() { history.append(p) } }"), screen])
            .allSatisfy { !$0.contains(NotWorkingHints.newestOnTopMark) })
    }
}

