import Testing
@testable import HarnessCore

struct PromptTrimTests {
    static func longFile() -> String {
        var lines = ["import Foundation", "", "final class Controller {", "    @Published var history: [String] = []", "    private var count = 0", ""]
        for n in 0..<100 {
            lines += ["    func helper\(n)() {", "        // filler line to make the file long enough to cut \(n)", "        count += \(n)",
                      "        print(\"helper \(n) has a long line of text that fills the file\")", "    }", ""]
        }
        lines += ["    func splitText(_ text: String) -> [String] {", "        text.components(separatedBy: \"、\")", "    }", "}"]
        return lines.joined(separator: "\n")
    }

    @Test func aLongFileShowsItsOutlineAndTheNamedFunction() throws {
        let file = Self.longFile()
        let shown = try #require(FileExcerpt.excerpt(of: file, instruction: "splitTextを、文の終わりだけで切るように直してください。"))
        #expect(shown.contains("text.components(separatedBy: \"、\")"))      // the named function, whole
        #expect(shown.contains("@Published var history"))                       // stored properties
        #expect(!shown.contains("helper 30 has a long line"))                   // other bodies left out
        #expect(shown.contains("行目 func helper30()"))                      // but listed in the outline
        #expect(shown.count < file.count / 2)
    }

    @Test func aLineNumberPicksItsFunctionAndNothingNamedSendsTheWholeFile() throws {
        let file = Self.longFile()
        let lines = file.components(separatedBy: "\n")
        let line = try #require(lines.firstIndex { $0.contains("count += 42") }) + 1
        let shown = try #require(FileExcerpt.excerpt(of: file, instruction: "- 行\(line): cannot convert value"))
        #expect(shown.contains("count += 42") && !shown.contains("count += 7\n"))
        #expect(FileExcerpt.excerpt(of: file, instruction: "全体を見直してください") == nil)
        #expect(FileExcerpt.excerpt(of: "let x = 1", instruction: "x を直す") == nil)
    }

    @Test func anExcerptAnswerIsPlacedInTheRealFile() throws {
        let file = Self.longFile()
        let answer = """
        <<<<<<< いま
            func splitText(_ text: String) -> [String] {
                text.components(separatedBy: "、")
        =======
            func splitText(_ text: String) -> [String] {
                text.components(separatedBy: "。")
        >>>>>>> 変更後
        """
        guard case let .changed(result) = ReplaceEdit.apply(answer, to: file) else { Issue.record("not placed"); return }
        #expect(result.contains("separatedBy: \"。\"") && result.contains("func helper99()"))
    }

    @Test func theInstructionKeepsWhatConcernsTheFile() {
        let instruction = """
        次のビルドエラーを解消してください。
        対象ファイル: App/Screen.swift
        - 行12: cannot find 'x' in scope

        調べてわかったこと(この依頼に関係するものだけを使う):
        App/Screen.swift は字幕を 1 件しか出していません。
        App/Translator.swift の splitText は読点でも切っています。
        iPhone で動いていたときのアプリの出力(最後の部分):
        \((1...30).map { "[log] line \($0)" }.joined(separator: "\n"))

        参考(この Mac の Xcode の SDK にある本物の宣言):
        public struct ForEach<Data, ID, Content> {
        }
        同じフレームワークの型:
        public struct ScrollGeometry : Equatable, Sendable
        public protocol TimelineSchedule
        """
        let short = InstructionTrim.shorten(instruction, targetPath: "App/Screen.swift")
        #expect(short.contains("App/Screen.swift は字幕を 1 件しか出していません。"))
        #expect(!short.contains("Translator.swift の splitText"))
        #expect(short.contains("[log] line 30") && !short.contains("[log] line 18\n") && short.contains("(前略: 18 行)"))
        #expect(short.contains("public struct ForEach") && !short.contains("TimelineSchedule"))
        #expect(short.contains("- 行12: cannot find 'x' in scope"))
        // Not a repair: a request to use a new Apple type keeps the list of the framework's types.
        let request = "SpeechAnalyzer を使ってください。\n同じフレームワークの型:\npublic struct SpeechTranscriber"
        #expect(InstructionTrim.shorten(request, targetPath: "A.swift").contains("SpeechTranscriber"))
    }
}

struct ExcerptAnswerTests {
    @Test func gapLinesCopiedOnBothSidesArePlacedPieceByPiece() {
        let file = "struct A {\n    var a = 1\n    func f() {}\n    var b = 2\n}"
        let both = "<<<<<<< いま\n    var a = 1\n⋯⋯ 省略(3〜3 行目)\n    var b = 2\n=======\n    var a = 10\n⋯⋯ 省略(3〜3 行目)\n    var b = 20\n>>>>>>> 変更後"
        #expect(ReplaceEdit.apply(both, to: file) == .changed("struct A {\n    var a = 10\n    func f() {}\n    var b = 20\n}"))
        let oneSide = "<<<<<<< いま\n    var a = 1\n⋯⋯ 省略(3〜3 行目)\n    var b = 2\n=======\n    var a = 10\n    var b = 20\n>>>>>>> 変更後"
        if case .failed = ReplaceEdit.apply(oneSide, to: file) {} else { Issue.record("a gap on one side was placed") }
    }
}

struct ReadAheadAndTriedTests {
    @Test func theReadAheadIsTheExactStartOfTheNextRequest() throws {
        let document = EditableSourceDocument(relativePath: "App/A.swift", content: "struct A {\n    var a = 1\n}")
        let ahead = try #require(ReplaceEdit.readAhead(document: document))
        let next = ReplaceEdit.messages(document: document, instruction: "a を 2 にしてください")
        #expect(ahead[0].content == next[0].content)
        #expect(next[1].content.hasPrefix(ahead[1].content))
        // A file the next request may show in part: no read-ahead.
        let middle = EditableSourceDocument(relativePath: "B.swift", content: String(repeating: "let x = 1\n", count: 1_500))
        #expect(ReplaceEdit.readAhead(document: middle) == nil)
    }

    @Test func aRepeatedRequestCarriesTheChangeThatDidNotWork() throws {
        let tried = TriedEdits()
        let key = TriedEdits.key(path: "A.swift", content: "let a = 1", instruction: "直して")
        #expect(tried.note(for: key) == nil)
        tried.record(key, before: "let a = 1", after: "let a = 2")
        let note = try #require(tried.note(for: key))
        #expect(note.contains("- let a = 1") && note.contains("+ let a = 2") && note.contains("同じ直しは返さず"))
        #expect(tried.note(for: TriedEdits.key(path: "A.swift", content: "let a = 2", instruction: "直して")) == nil)
    }
}
