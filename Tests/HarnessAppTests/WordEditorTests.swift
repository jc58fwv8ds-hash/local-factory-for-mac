import AppKit
import Foundation
import Testing
@testable import HarnessApp

/// File operations stage 5 (2026-10-11): text in a .docx is rewritten into a new file; run formatting stays.
struct WordEditorTests {
    @Test func replacementsKeepTheRunFormattingAndTheOriginal() throws {
        let paragraph = #"<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>お見積</w:t></w:r><w:r><w:t xml:space="preserve">金額は 12,000 円です。</w:t></w:r></w:p>"#
        let one = WordEditor.replacing("12,000", with: "15,000", in: paragraph)
        #expect(WordEditor.text(of: one) == "お見積金額は 15,000 円です。")
        #expect(one.contains("<w:b/></w:rPr><w:t xml:space=\"preserve\">お見積</w:t>"))   // the bold run is untouched
        let spanning = WordEditor.replacing("見積金額", with: "請求額", in: paragraph)
        #expect(WordEditor.text(of: spanning) == "お請求額は 12,000 円です。")
        let deleted = WordEditor.replacing("お見積", with: "", in: paragraph)
        #expect(WordEditor.text(of: deleted) == "金額は 12,000 円です。")
        #expect(WordEditor.text(of: WordEditor.replacing("A&B", with: "C<D", in: #"<w:p><w:r><w:t>A&amp;B</w:t></w:r></w:p>"#)) == "C<D")
    }

    @Test func aDocxIsEditedIntoANewFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("word-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("案内.docx")
        let text = NSAttributedString(string: "社内勉強会のご案内\n日時は10月20日です。\n場所は第2会議室です。")
        try text.data(from: NSRange(location: 0, length: text.length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: source)
        let original = try Data(contentsOf: source)
        #expect(try WordEditor.paragraphs(of: source).contains("日時は10月20日です。"))
        let output = folder.appendingPathComponent("案内_編集済み.docx")
        let changes = try WordEditor.apply([.init(find: "10月20日", replace: "10月27日"), .init(find: "第2会議室", replace: "大会議室")],
                                           to: source, output: output)
        #expect(changes.map(\.after) == ["日時は10月27日です。", "場所は大会議室です。"])
        #expect(try Data(contentsOf: source) == original)
        let reread = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                            documentAttributes: nil).string
        #expect(reread.contains("日時は10月27日です。") && reread.contains("場所は大会議室です。"))
        #expect(throws: WordEditor.Failure.self) { try WordEditor.apply([.init(find: "存在しない文", replace: "x")], to: source,
                                                                         output: folder.appendingPathComponent("x.docx")) }
    }

    /// 2026-10-12 review: a text box's paragraphs sit inside a body paragraph. Each is found and edited on its own, and the
    /// body paragraph around it keeps its own text.
    @Test func paragraphsInsideATextBoxAreEditedOnTheirOwn() {
        let xml = #"<w:body><w:p><w:r><w:t>本文の前</w:t></w:r><w:r><w:pict><w:txbxContent><w:p><w:r><w:t>箱の中の 10 月</w:t></w:r></w:p></w:txbxContent></w:pict></w:r><w:r><w:t>本文の後</w:t></w:r></w:p><w:p><w:pPr/><w:r><w:t>次の段落</w:t></w:r></w:p></w:body>"#
        let texts = WordEditor.paragraphRanges(in: xml).map { WordEditor.text(of: String(xml[$0])) }
        #expect(texts == ["箱の中の 10 月", "次の段落"])
        let box = WordEditor.paragraphRanges(in: xml)[0]
        var edited = xml
        edited.replaceSubrange(box, with: WordEditor.replacing("10 月", with: "11 月", in: String(xml[box])))
        #expect(edited.contains("箱の中の 11 月") && edited.contains("<w:t>本文の前</w:t>") && edited.contains("<w:t>本文の後</w:t>"))
    }
}
