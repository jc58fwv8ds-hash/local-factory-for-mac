import AppKit
import HarnessCore
import SwiftUI

/// The shared response renderer; inference and hover lifecycle live outside the View.
struct ExplainedResponseText: NSViewRepresentable {
    let text: String
    let model: ModelSelection?
    let service: any TermExplanationProviding
    var isSuspended = false
    var style: HarnessTextStyle = .subheadline

    func makeCoordinator() -> TermExplanationPresenter {
        TermExplanationPresenter(service: service)
    }

    func makeNSView(context: Context) -> ResponseTextView {
        let view = ResponseTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setAccessibilityIdentifier(HarnessAccessibilityID.responseText)
        view.setAccessibilityHelp("言葉にカーソルを少し合わせると意味を説明します。右クリックの「意味を説明」も使えます。")
        view.onTerm = { [weak presenter = context.coordinator, weak view] term, rect, immediate in
            guard let view else { return }
            presenter?.hover(term, rect: rect, in: view, immediate: immediate)
        }
        view.onDismiss = { [weak presenter = context.coordinator] in presenter?.dismiss() }
        return view
    }

    func updateNSView(_ view: ResponseTextView, context: Context) {
        context.coordinator.configure(model: model, isSuspended: isSuspended)
        let font = HarnessTypography.resolvedFont(size: style.size, weight: style.defaultWeight)
        if view.string != text || view.font != font {
            context.coordinator.dismiss()
            view.textStorage?.setAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
            view.termIndex = ResponseTermIndex(text: text)
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResponseTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.measuredHeight(for: width))
    }

    static func dismantleNSView(_ view: ResponseTextView, coordinator: TermExplanationPresenter) {
        coordinator.dismiss()
        view.onTerm = nil
        view.onDismiss = nil
    }
}
