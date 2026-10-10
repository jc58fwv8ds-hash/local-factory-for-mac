import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

struct InferenceResponseTimingTests {
    private let request = InferenceRequest(
        runtime: .ollama, modelIdentifier: "fixture",
        messages: [.init(role: .system, content: "方針"), .init(role: .user, content: "教えて👨‍👩‍👦")]
    )

    @Test func monotonicTimingSeparatesFirstContentFromReceivingWithoutStoringText() throws {
        let start = ContinuousClock.now
        var timer = InferenceResponseTimer(request: request, at: start)
        timer.observe(hasVisibleContent: false, at: start.advanced(by: .seconds(2)))
        timer.observe(hasVisibleContent: true, at: start.advanced(by: .milliseconds(3250)))
        timer.observe(hasVisibleContent: true, at: start.advanced(by: .seconds(7)))
        let measured = timer.measurement(at: start.advanced(by: .milliseconds(8500)))
        #expect(measured.firstContentSeconds == 3.25)
        #expect(measured.totalSeconds == 8.5)
        #expect(measured.receivingSeconds == 5.25)
        #expect(measured.promptCharacters == 6) // Swift characters, not bytes or tokens.
        #expect(measured.promptComposition.messageCount == 2)
        #expect(measured.promptComposition.systemCharacters == 2)
        #expect(measured.promptComposition.userCharacters == 4)
        #expect(measured.promptComposition.totalCharacters == measured.promptCharacters)
        let json = String(decoding: try JSONEncoder().encode(measured), as: UTF8.self)
        #expect(!json.contains("教えて") && !json.contains("fixture"))
    }

    @Test func promptCompositionSeparatesConversationFromBoundedReferences() {
        let messages = [
            InferenceMessage(role: .system, content: "方針"),
            InferenceMessage(role: .user, content: "本人の質問"),
            InferenceMessage(role: .assistant, content: "過去の案"),
            InferenceMessage(
                role: .user,
                content: "[HARNESS_SOURCE_REFERENCE]\ncode\n[END_HARNESS_SOURCE_REFERENCE]"
            ),
            InferenceMessage(
                role: .user,
                content: "[HARNESS_EXTERNAL_REVIEW_REFERENCE]\nreview\n[END_HARNESS_EXTERNAL_REVIEW_REFERENCE]"
            )
        ]
        let request = InferenceRequest(
            runtime: .ollama, modelIdentifier: "fixture", messages: messages
        )
        let composition = InferenceResponseTimer(request: request).measurement().promptComposition
        #expect(composition.messageCount == messages.count)
        #expect(composition.systemCharacters == messages[0].content.count)
        #expect(composition.userCharacters == messages[1].content.count)
        #expect(composition.assistantCharacters == messages[2].content.count)
        #expect(composition.sourceCharacters == messages[3].content.count)
        #expect(composition.externalReviewCharacters == messages[4].content.count)
        #expect(composition.totalCharacters == messages.reduce(0) { $0 + $1.content.count })
    }

    @Test func markerWordsInsideOrdinaryConversationDoNotChangeTheBreakdown() {
        let content = "HARNESS_SOURCE_REFERENCEという文字を説明して"
        let request = InferenceRequest(
            runtime: .ollama, modelIdentifier: "fixture",
            messages: [InferenceMessage(role: .user, content: content)]
        )
        let composition = InferenceResponseTimer(request: request).measurement().promptComposition
        #expect(composition.userCharacters == content.count)
        #expect(composition.sourceCharacters == 0 && composition.externalReviewCharacters == 0)
    }

    @Test func emptyOrHiddenContentHasNoInventedFirstContentTime() {
        let start = ContinuousClock.now
        var timer = InferenceResponseTimer(request: request, at: start)
        timer.observe(hasVisibleContent: false, at: start.advanced(by: .seconds(1)))
        let result = timer.measurement(at: start.advanced(by: .seconds(2)))
        #expect(result.firstContentSeconds == nil && result.receivingSeconds == nil)
        #expect(result.totalSeconds == 2)
        #expect(timer.measurement(at: start.advanced(by: .seconds(-1))).totalSeconds == 0)
    }

    @Test func performanceBelongsOnlyToExactLastLocalAnswerInSameProject() {
        var project = HarnessProject.starter
        let answer = ConversationMessage(role: .assistant, content: "仮の案です。")
        project.conversation = [answer]
        let result = ConversationPerformance(
            projectID: project.id, responseID: answer.id,
            attempts: [InferenceResponseTimer(request: request).measurement()]
        )
        #expect(result.belongs(to: project))
        let otherProject = HarnessProject(
            name: "別", summary: "", targets: [], stage: .design, progress: 0,
            currentActivity: "", workItems: [], activity: [], conversation: [answer]
        )
        #expect(!result.belongs(to: otherProject))
        project.conversation.append(ConversationMessage(role: .user, content: "続けて"))
        #expect(!result.belongs(to: project))
        project.conversation = [.init(role: .assistant, content: "外部資料", origin: .externalReview)]
        #expect(!result.belongs(to: project))
    }
}
