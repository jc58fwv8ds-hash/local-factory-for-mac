import HarnessCore
import Testing
@testable import TaskOrchestrator

struct SharedContextMessagesTests {
    @Test func fileMapsMoveToTheSystemMessageAndInstructionsStay() {
        let prompt = "Plan before editing.\n        EDITABLE: {\"Sources/A/A.swift\":\"struct A {}\\n\"}\n        READ-ONLY: {}\nReturn JSON only."
        let messages = SharedContextMessages.messages(for: prompt)
        #expect(messages.map(\.role) == [.system, .user])
        #expect(messages[0].content.hasSuffix("EDITABLE: {\"Sources/A/A.swift\":\"struct A {}\\n\"}\nREAD-ONLY: {}"))
        #expect(messages[1].content.hasPrefix("Plan before editing.") && messages[1].content.contains("Return JSON only."))
        #expect(!messages[1].content.contains("struct A"))
        #expect(messages[1].content.contains("EDITABLE: (file map in the system message)\n        READ-ONLY: (file map in the system message)\nReturn"))
    }

    @Test func samePackageGivesTheSameSystemMessageForPlanAndProposal() {
        let files = "EDITABLE: {\"Sources/A/A.swift\":\"x\"}\nREAD-ONLY: {}"
        let plan = SharedContextMessages.messages(for: "Plan.\n" + files + "\nReturn requirements.")
        let proposal = SharedContextMessages.messages(for: "Objective.\nRules.\n" + files + "\nAccepted plan: {}")
        #expect(plan[0] == proposal[0])
    }

    @Test func promptWithoutFileMapsIsUnchanged() {
        #expect(SharedContextMessages.messages(for: "Hello") == [.init(role: .user, content: "Hello")])
    }
}
