import Foundation
import HarnessCore
import TaskOrchestrator

/// Asking before building (2026-10-19): a new code change first gets up to three questions about readings that would give
/// different results; the user answers them on the card (or leaves them to the builder) and only then is it built.
/// Measured on C2: answered by a person 16 → 18 of 22, false successes 3 → 1; the builder answering itself made it worse,
/// so the builder never answers its own questions.
extension WorkspaceStore {
    func askBeforeBuilding(_ change: ChatChange,
                           context: (service: any OrchestratedEditing, root: String, model: ModelSelection)) async {
        let sources = ClarifyQuestions.sources(in: URL(fileURLWithPath: context.root))
        let request = InferenceRequest(runtime: context.model.runtime, modelIdentifier: context.model.identifier, messages: [
            InferenceMessage(role: .user, content: ClarifyQuestions.prompt(objective: change.instruction, sources: sources))],
            maximumOutputTokens: 1024, temperature: 0)
        var response = ""
        do {
            for try await piece in await inferenceProvider.events(for: request) { response += piece }
        } catch {
            response = ""   // no questions: build as asked
        }
        guard change.status == .asking else { return }
        let questions = ClarifyQuestions.questions(in: response)
        guard !questions.isEmpty else {
            change.status = .running
            await runChatChange(change, context: context)
            return
        }
        change.questions = questions.map { ClarifyQuestions.Point(question: $0, answer: "") }
        appendAssistantNote("作り始める前に \(questions.count) 点だけ確かめさせてください。答えたところだけ守って作ります(空欄はおまかせ)。")
    }

    /// The user's answers (blank = おまかせ): the request goes to the builder with the answered points.
    func buildWithAnswers(_ change: ChatChange, answers: [String]) {
        guard change.status == .asking, let context = chatCodeChangeContext else { return }
        for index in change.questions.indices where index < answers.count {
            change.questions[index].answer = answers[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let instruction = ClarifyQuestions.objective(change.instruction, with: change.questions)
        let built = ChatChange(id: change.id, instruction: instruction)
        built.questions = change.questions
        chatChanges[change.id] = built
        Task { await runChatChange(built, context: context) }
    }
}
