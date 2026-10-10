import Foundation
import HarnessCore
import Testing

/// These test prompt wiring, not semantic model quality. Real outputs use the opt-in paired suite.
struct NaturalLanguageExplanationTests {
    @Test(arguments: ["なんで？短く教えてちょ", "理由を簡潔に説明してください。"])
    func explanationContractIsSharedWithoutChangingUserWords(_ raw: String) {
        var project = HarnessProject.starter
        project.conversation = [ConversationMessage(role: .user, content: raw)]
        let before = project
        let messages = ProjectPromptBuilder.messages(for: project)
        let system = messages.first?.content ?? ""
        #expect(system.components(separatedBy: NaturalLanguageExplanationGuidance.instructions).count == 2)
        #expect(messages.last?.role == .user)
        #expect(messages.last?.content.hasPrefix(raw) == true)
        #expect(messages.last?.content.contains(ConversationResponseGuard.instructions) == true)
        #expect(messages.last?.content.contains("直接通信より安定するため") == true)
        #expect(project == before)
        let summaryGuidance = NaturalLanguageInstructionAdapter.responseGuidance(for: raw)
        #expect(summaryGuidance.contains(NaturalLanguageExplanationGuidance.instructions))
    }

    @Test func reasonsRemainEvidenceBoundAndDoNotExpandApprovalOrRequireLongAnswers() {
        let contract = NaturalLanguageExplanationGuidance.instructions
        #expect(contract.contains("役割の言い換えだけで済ませず"))
        #expect(contract.contains("後から前提が変われば理由も見直し"))
        #expect(contract.contains("根拠のない理由・数値・機器の制限を作らない"))
        #expect(contract.contains("学習時の知識やもっともらしい推測で補わない"))
        #expect(contract.contains("同じ条件の変更前後を測るまでは説明できない"))
        #expect(contract.contains("必要な条件や未確認の区別を落とさない"))
        #expect(contract.contains("設計・提案・未確認とされた話は「案では」"))
        #expect(contract.contains("指定された文数に収めて"))
        #expect(contract.contains("実行していない作業を、実行済みのように書かない"))
    }
}
