import Testing
@testable import TaskOrchestrator

struct ClarifyQuestionsTests {
    @Test func answeredPointsGoToTheBuilderButAreNotClauses() {
        let objective = ClarifyQuestions.objective("10 を上限にして", with: [
            .init(question: "10 ちょうどは含めますか?", answer: "はい"),
            .init(question: "負の値は?", answer: "")])
        #expect(objective == "10 を上限にして\n\n確認済みの点:\n・10 ちょうどは含めますか? → はい")
        // Clauses are counted on the user's request only, not on the answered points (2026-10-20).
        #expect(ClarifyQuestions.request(of: objective) == "10 を上限にして")
        #expect(ClarifyQuestions.request(of: "10 を上限にして") == "10 を上限にして")
    }

    @Test func questionsAreReadFromNumberedOrPlainLinesAtMostThree() {
        let text = "1. Q: 一つ目?\nQ：二つ目?\n関係ない行\nQ: 三つ目?\nQ: 四つ目?"
        #expect(ClarifyQuestions.questions(in: text) == ["一つ目?", "二つ目?", "三つ目?"])
        #expect(ClarifyQuestions.questions(in: "なし").isEmpty)
    }
}
