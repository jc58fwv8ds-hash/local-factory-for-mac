import AppKit
import HarnessCore

/// Native text selection, wrapping and word hit-testing, without inference concerns.
@MainActor
final class ResponseTextView: NSTextView {
    var termIndex = ResponseTermIndex(text: "")
    var onTerm: ((ResponseTerm?, NSRect, Bool) -> Void)?
    var onDismiss: (() -> Void)?
    private var hoverTracking: NSTrackingArea?
    private var menuTerm: ResponseTerm?

    func measuredHeight(for width: CGFloat) -> CGFloat {
        // SwiftUI probes several widths. Never mutate the live text container during a probe.
        let storage = NSTextStorage(attributedString: attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return max(18, ceil(layout.usedRect(for: container).height) + 2)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) {
        onTerm?(nil, .zero, false)
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onDismiss?()
        super.scrollWheel(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onDismiss?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menuTerm = term(at: convert(event.locationInWindow, from: nil))
            ?? termIndex.term(atUTF16Offset: selectedRange().location)
        if let menuTerm {
            let item = NSMenuItem(
                title: "「\(menuTerm.text)」の意味を説明",
                action: #selector(explainMenuTerm),
                keyEquivalent: ""
            )
            item.target = self
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func explainMenuTerm() {
        guard let menuTerm else { return }
        onTerm?(menuTerm, rect(for: menuTerm), true)
    }

    func highlight(_ term: ResponseTerm?) {
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        layoutManager?.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
        guard let term else { return }
        layoutManager?.addTemporaryAttributes([
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.controlAccentColor
        ], forCharacterRange: term.range)
    }

    func rect(for term: ResponseTerm) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: term.range, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func updateHover(_ event: NSEvent) {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let term = term(at: convert(event.locationInWindow, from: nil))
        onTerm?(term, term.map { rect(for: $0) } ?? .zero, false)
    }

    func term(at point: NSPoint) -> ResponseTerm? {
        guard let layoutManager, let textContainer, !string.isEmpty else { return nil }
        let position = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: position, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        // glyphIndex returns the nearest glyph even in blank space; require an actual hit.
        guard bounds.contains(position) else { return nil }
        return termIndex.term(atUTF16Offset: layoutManager.characterIndexForGlyph(at: glyph))
    }
}
