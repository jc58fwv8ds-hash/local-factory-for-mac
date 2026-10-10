import AppKit
import HarnessCore
import SwiftUI

/// AppKit presentation adapter. Timing and inference belong to TermExplanationSession.
@MainActor
final class TermExplanationPresenter: NSObject, NSPopoverDelegate {
    private let session: TermExplanationSession
    private weak var sourceView: ResponseTextView?
    private var sourceRect = NSRect.zero
    private var popover: NSPopover?

    init(service: any TermExplanationProviding) {
        session = TermExplanationSession(service: service)
        super.init()
        session.onPresent = { [weak self] in self?.present() }
        session.onDismiss = { [weak self] in self?.closePopover() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationResigned),
            name: NSApplication.didResignActiveNotification, object: nil
        )
    }

    func configure(model: ModelSelection?, isSuspended: Bool) {
        session.configure(model: model, isSuspended: isSuspended)
    }

    func hover(_ term: ResponseTerm?, rect: NSRect, in view: ResponseTextView, immediate: Bool) {
        session.hover(term, immediate: immediate)
        if term != nil {
            sourceView = view
            sourceRect = rect
        }
    }

    func dismiss() {
        session.dismiss()
        sourceView = nil
    }

    private func closePopover() {
        sourceView?.highlight(nil)
        let previous = popover
        popover = nil
        previous?.delegate = nil
        previous?.close()
    }

    func popoverDidClose(_ notification: Notification) { dismiss() }

    private func present() {
        guard let view = sourceView, view.window?.isVisible == true,
              let term = session.currentTerm else { dismiss(); return }
        let panel = NSPopover()
        panel.behavior = .transient
        panel.animates = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: TermExplanationPopover(
            display: session.display,
            onHover: { [weak self] inside in self?.session.setPopoverHovered(inside) },
            onClose: { [weak self] in self?.dismiss() }
        ))
        popover = panel
        view.highlight(term)
        panel.show(relativeTo: sourceRect, of: view, preferredEdge: .maxY)
    }

    @objc private func applicationResigned() { dismiss() }
}
