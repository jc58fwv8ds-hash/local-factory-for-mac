import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct TermExplanationSessionTests {
    private let model = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)

    @Test func leavingBeforeDwellNeverStartsInference() async throws {
        let provider = HoverExplanationFixture()
        let session = makeSession(provider, dwell: .milliseconds(100), grace: .milliseconds(300))
        session.hover(try term("API"))
        try await Task.sleep(for: .milliseconds(30))
        session.hover(nil)
        #expect(session.currentTerm == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!session.isPresented)
        #expect(await provider.words.isEmpty)
    }

    @Test func wordChangesDiscardPendingWorkAndRepeatedHoverDoesNotRegenerate() async throws {
        let provider = HoverExplanationFixture()
        let session = makeSession(provider)
        session.hover(try term("API"))
        session.hover(try term("JSON"))
        try await waitUntil { session.isPresented && !session.display.isLoading }
        session.hover(try term("JSON"))
        try await Task.sleep(for: .milliseconds(80))
        #expect(await provider.words == ["JSON"])
        #expect(session.display.word == "JSON")
        session.dismiss()
    }

    @Test func popupEntryBeforeTextExitKeepsExplanationOpen() async throws {
        let provider = HoverExplanationFixture()
        let session = makeSession(provider)
        session.hover(try term("API"), immediate: true)
        try await waitUntil { session.isPresented }
        // AppKit does not guarantee ordering between overlapping tracking areas.
        session.setPopoverHovered(true)
        session.hover(nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(session.isPresented)
        session.setPopoverHovered(false)
        try await waitUntil { !session.isPresented }
    }

    @Test func popupEntryAfterTextExitCancelsDeparture() async throws {
        let provider = HoverExplanationFixture()
        let session = makeSession(provider)
        session.hover(try term("API"), immediate: true)
        try await waitUntil { session.isPresented }
        session.hover(nil)
        session.setPopoverHovered(true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(session.isPresented)
        session.dismiss()
        #expect(session.currentTerm == nil)
    }

    @Test func missingOrBusyModelShowsGuidanceWithoutInference() async throws {
        let provider = HoverExplanationFixture()
        let session = makeSession(provider)
        session.configure(model: nil, isSuspended: false)
        session.hover(try term("API"), immediate: true)
        try await waitUntil { session.isPresented }
        #expect(session.display.body.contains("AIモデルを選ぶ"))
        #expect(!session.display.isLoading)
        session.configure(model: model, isSuspended: true)
        #expect(!session.isPresented)
        session.hover(try term("API"), immediate: true)
        try await waitUntil { session.isPresented }
        #expect(session.display.body.contains("作業を優先"))
        #expect(await provider.words.isEmpty)
        session.dismiss()
    }

    @Test func cancelledOldResultCannotReplaceNewWord() async throws {
        let provider = ControlledHoverFixture()
        let session = makeSession(provider)
        session.hover(try term("API"), immediate: true)
        try await waitUntil { await provider.hasPending("API") }
        session.hover(try term("JSON"), immediate: true)
        try await waitUntil { await provider.hasPending("JSON") }
        await provider.complete("JSON")
        try await waitUntil { !session.display.isLoading }
        await provider.complete("API")
        try await Task.sleep(for: .milliseconds(40))
        #expect(session.display.word == "JSON")
        #expect(session.display.body == "JSONの解説")
        session.dismiss()
    }

    @Test func changingModelOrSuspendingCancelsPendingHover() async throws {
        let provider = HoverExplanationFixture()
        let session = makeSession(provider)
        session.hover(try term("API"))
        session.configure(model: model, isSuspended: true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(session.currentTerm == nil)
        #expect(await provider.words.isEmpty)
    }

    private func makeSession(
        _ service: any TermExplanationProviding,
        dwell: Duration = .milliseconds(40),
        grace: Duration = .milliseconds(30)
    ) -> TermExplanationSession {
        let session = TermExplanationSession(service: service, dwell: dwell, departureGrace: grace)
        session.configure(model: model, isSuspended: false)
        return session
    }

    private func term(_ word: String) throws -> ResponseTerm {
        try #require(ResponseTermIndex(text: "\(word)の意味を確認します。").terms.first { $0.text == word })
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await predicate())
    }
}

private actor HoverExplanationFixture: TermExplanationProviding {
    private(set) var words: [String] = []

    func explanation(for term: ResponseTerm, model: ModelSelection) -> String {
        words.append(term.text)
        return "\(term.text)の解説"
    }
}

private actor ControlledHoverFixture: TermExplanationProviding {
    private var pending: [String: CheckedContinuation<String, Never>] = [:]

    func explanation(for term: ResponseTerm, model: ModelSelection) async -> String {
        await withCheckedContinuation { pending[term.text] = $0 }
    }

    func hasPending(_ word: String) -> Bool { pending[word] != nil }

    func complete(_ word: String) {
        pending.removeValue(forKey: word)?.resume(returning: "\(word)の解説")
    }
}
