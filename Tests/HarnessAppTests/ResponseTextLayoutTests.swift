import AppKit
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
struct ResponseTextLayoutTests {
    @Test func measurementNeverResizesTheLiveTextView() throws {
        let view = makeView("日本語とEnglishの長い説明です。" + String(repeating: "折り返しを確認します。", count: 40))
        let frame = view.frame
        let containerSize = try #require(view.textContainer?.containerSize)
        let content = view.attributedString()
        let narrow = view.measuredHeight(for: 180)
        let wide = view.measuredHeight(for: 600)
        let narrowAgain = view.measuredHeight(for: 180)
        #expect(narrow > wide)
        #expect(narrow == narrowAgain)
        #expect(view.frame == frame)
        #expect(view.textContainer?.containerSize == containerSize)
        #expect(view.attributedString() == content)
    }

    @Test func hitTestingRejectsWhitespaceAndFindsJapaneseAndEnglish() throws {
        let view = makeView("🎉 APIのテスト\n次はビルドです。")
        for word in ["API", "テスト", "ビルド"] {
            let term = try #require(view.termIndex.terms.first { $0.text == word })
            let rect = view.rect(for: term)
            #expect(view.term(at: NSPoint(x: rect.midX, y: rect.midY)) == term)
            #expect(view.term(at: NSPoint(x: 490, y: rect.midY)) == nil)
        }
        #expect(view.term(at: NSPoint(x: 10, y: 180)) == nil)
    }

    @Test func wordHighlightNeverChangesStoredTextOrSelection() throws {
        let view = makeView("APIから情報を読みます。")
        let term = try #require(view.termIndex.terms.first { $0.text == "API" })
        view.setSelectedRange(term.range)
        let original = view.attributedString()
        view.highlight(term)
        #expect(view.selectedRange() == term.range)
        #expect(view.attributedString() == original)
        view.highlight(nil)
        #expect(view.attributedString() == original)
    }

    @Test func measuredHeightMatchesTheDisplayedGlyphs() throws {
        let view = makeView(String(repeating: "APIと日本語の長い説明を折り返します。\n", count: 20))
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        for width: CGFloat in [180, 600, 300] {
            view.setFrameSize(NSSize(width: width, height: 200))
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let expected = ceil(layout.usedRect(for: container).height) + 2
            #expect(view.measuredHeight(for: width) == expected)
        }
    }

    private func makeView(_ text: String) -> ResponseTextView {
        let view = ResponseTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.isEditable = false
        view.isSelectable = true
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        view.font = HarnessTypography.resolvedFont(size: 13, weight: .regular)
        view.termIndex = ResponseTermIndex(text: text)
        return view
    }
}
