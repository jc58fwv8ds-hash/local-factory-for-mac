import HarnessCore
import Testing

struct UnfinishedCodeTests {
    // The lines 14Translate's run saved on 2026-11-16 and still called done.
    @Test func standInsAndNotSupportedStubsAreFound() {
        let content = """
        struct SlangEditorView: View {
            var body: some View {
                // ここに用語のリストと編集UIを追加
                Text("スラング用語集の編集画面")
            }
        }
        Button {
            selectedLanguage = option.code
            // controller.setLanguage(option.code)
        }
        private func update(_ language: RecognitionLanguage) {
            print("[TranslationController] Warning: SpeechListener does not support dynamic locale update")
        }
        """
        let found = UnfinishedCode.findings(in: content)
        #expect(found.contains("// ここに用語のリストと編集UIを追加"))
        #expect(found.contains("// controller.setLanguage(option.code)"))
        #expect(found.contains { $0.contains("does not support") })
        #expect(UnfinishedCode.feedback(found).contains("全文を書き直して"))
    }

    @Test func finishedCodeAndOldNotesAreLeftAlone() {
        let finished = """
        TextField("Placeholder text", text: $name) // the field's hint
        let count = items.count // number of items
        // 文の終わりで訳し直す
        """
        #expect(UnfinishedCode.findings(in: finished).isEmpty)
        let realCheck = """
        } else {
            // If the current locale is not supported, fall back to a supported locale
            let fallbackLocale = Locale(identifier: "en-US")
            print("[SpeechListener] Locale not supported, using en-US.")
            self.locale = fallbackLocale
        }
        """
        #expect(UnfinishedCode.findings(in: realCheck).isEmpty)
        let old = "// TODO: tidy later\nlet a = 1"
        #expect(UnfinishedCode.findings(in: old + "\nlet b = 2", previous: old).isEmpty)
    }

    @Test func eachFileWriterSeesTheUsersOwnList() {
        let request = "用語集の最初の中身は No cap=マジで、güey=おまえ。"
        let target = ArtifactCreationTarget(relativePath: "App/SlangGlossary.swift", instruction: "指定された一覧を初期値にする")
        let plan = ArtifactCreationPlan(instruction: request, targets: [
            target, ArtifactCreationTarget(relativePath: "App/Screen.swift", instruction: "画面")
        ])
        let written = plan.writerInstruction(for: target)
        #expect(written.hasPrefix("指定された一覧を初期値にする"))
        #expect(written.contains("No cap=マジで、güey=おまえ"))
    }
}
