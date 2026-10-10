import Foundation
import HarnessCore
import Observation

@MainActor
@Observable
final class TermExplanationDisplay {
    var word = ""
    var body = "この文章での意味を考えています…"
    var isLoading = true
}

/// Testable hover/inference lifecycle. No windows, text layout, or project mutations.
@MainActor
final class TermExplanationSession {
    let display = TermExplanationDisplay()
    private(set) var currentTerm: ResponseTerm?
    private(set) var isPresented = false
    var onPresent: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let service: any TermExplanationProviding
    private let dwell: Duration
    private let departureGrace: Duration
    private var model: ModelSelection?
    private var isSuspended = false
    private var isPopoverHovered = false
    private var task: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?

    init(
        service: any TermExplanationProviding,
        dwell: Duration = .milliseconds(650),
        departureGrace: Duration = .milliseconds(250)
    ) {
        self.service = service
        self.dwell = dwell
        self.departureGrace = departureGrace
    }

    func configure(model: ModelSelection?, isSuspended: Bool) {
        if self.model != model || self.isSuspended != isSuspended { dismiss() }
        self.model = model
        self.isSuspended = isSuspended
    }

    func hover(_ term: ResponseTerm?, immediate: Bool = false) {
        guard let term else {
            // A grace period is only for moving into an already-visible explanation.
            if isPresented { scheduleDismissal() } else { dismiss() }
            return
        }
        leaveTask?.cancel()
        if currentTerm == term, !immediate { return }
        dismiss()
        currentTerm = term
        task = Task { [weak self, dwell] in
            do {
                if !immediate { try await Task.sleep(for: dwell) }
                guard let self, !Task.isCancelled else { return }
                self.present(term)
                guard self.isPresented, let model = self.model, !self.isSuspended else { return }
                let body = try await self.service.explanation(for: term, model: model)
                try Task.checkCancellation()
                self.display.body = body
                self.display.isLoading = false
            } catch is CancellationError {
                // Pointer movement is normal; cancelled output must never replace newer text.
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.display.body = "今は解説を作れませんでした。ローカルAIの接続を確認して、もう一度言葉にカーソルを合わせてね。"
                self.display.isLoading = false
            }
        }
    }

    func setPopoverHovered(_ inside: Bool) {
        isPopoverHovered = inside
        if inside { leaveTask?.cancel() } else { scheduleDismissal() }
    }

    func dismiss() {
        task?.cancel()
        task = nil
        leaveTask?.cancel()
        leaveTask = nil
        currentTerm = nil
        isPresented = false
        isPopoverHovered = false
        onDismiss?()
    }

    private func present(_ term: ResponseTerm) {
        display.word = term.text
        display.isLoading = model != nil && !isSuspended
        display.body = model == nil
            ? "AIモデルを選ぶと、この言葉の意味を説明できるよ。"
            : isSuspended
                ? "今は制作の作業を優先しています。終わってから、もう一度カーソルを合わせてね。"
                : "この文章での意味を考えています…"
        isPresented = true
        onPresent?()
    }

    private func scheduleDismissal() {
        guard currentTerm != nil, !isPopoverHovered,
              leaveTask == nil || leaveTask?.isCancelled == true else { return }
        leaveTask = Task { [weak self, departureGrace] in
            do { try await Task.sleep(for: departureGrace) } catch { return }
            guard self?.isPopoverHovered == false else { return }
            self?.dismiss()
        }
    }
}
