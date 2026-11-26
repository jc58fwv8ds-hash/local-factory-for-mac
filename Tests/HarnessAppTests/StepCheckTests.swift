import HarnessCore
import Testing

struct StepCheckTests {
    // 2026-11-16: the step asked to stop translating every partial result; the change only skipped the same sentence twice.
    @Test func aChangeThatLeavesOutTheStepIsSentBackWithWhatIsMissing() {
        let diff = StepCheck.diffText([
            FileDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "func handle(_ t: String) {"),
            FileDiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 2, text: "    if t == last { return }")
        ])
        #expect(diff == "+     if t == last { return }")
        let ask = StepCheck.request(step: "途中結果のたびに訳すのをやめ、区切りごとに 1 回だけ訳す", path: "App/Controller.swift", diff: diff)
        #expect(ask.contains("途中結果のたびに訳すのをやめ") && ask.contains("MISSING:"))
        #expect(StepCheck.missing(from: "OK") == nil)
        #expect(StepCheck.missing(from: "MISSING: 途中結果をまだ毎回訳しています。") == "途中結果をまだ毎回訳しています。")
        #expect(StepCheck.feedback("x").contains("全文を書き直して"))
        #expect(StepCheck.missingNoted(in: "直して" + StepCheck.feedback("途中結果を毎回訳している")) == "途中結果を毎回訳している")
        #expect(StepCheck.missingNoted(in: "直して") == nil)
    }

    @Test func theCheckSeesWhatTheFileAlreadyHad() {
        let ask = StepCheck.request(step: "使えないときは代わりの聞き取りを使う", path: "App/Listener.swift", diff: "+ let a = 1",
                                    file: "func startFallback() { recognizer.recognitionTask(with: request) }")
        #expect(ask.contains("変更後のファイル全文"))
        #expect(ask.contains("recognitionTask(with: request)"))
        #expect(ask.contains("前からあって今回変えていない部分でも"))
    }

    @Test func aLongFileShowsTheFunctionsTheStepNames() {
        let filler = (0..<400).map { "    func filler\($0)() { let value = \($0) * 2; print(value, \"padding text for length\") }" }.joined(separator: "\n")
        let file = "final class Controller {\n" + filler + "\n    func handleTranscript(_ text: String) {\n        queue.append(text)\n    }\n}"
        #expect(file.count > StepCheck.maximumFileCharacters)
        let ask = StepCheck.request(step: "handleTranscript に途中の文を送らない", path: "C.swift", diff: "+ x", file: file)
        #expect(ask.contains("queue.append(text)"))
        #expect(ask.contains("handleTranscript"))
        #expect(!ask.contains("filler399"))
    }

    @Test func indentationOnlyChangesAreLeftOut() {
        let diff = StepCheck.diffText([
            FileDiffLine(kind: .removal, oldLineNumber: 1, newLineNumber: nil, text: "        let a = 1"),
            FileDiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: "                let a = 1"),
            FileDiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 2, text: "        outStatus.pointee = .noDataNow")
        ])
        #expect(diff == "+         outStatus.pointee = .noDataNow")
    }

    // 2026-11-25 review: an answer that could not be read was taken as OK and the change was saved as checked.
    @Test func anUnreadableAnswerIsNotAPass() {
        #expect(StepCheck.verdict(from: "OK") == .ok)
        #expect(StepCheck.verdict(from: "OK。\n変更は頼まれたとおりです。") == .ok)
        #expect(StepCheck.verdict(from: "**OK**") == .ok)
        #expect(StepCheck.verdict(from: "MISSING: 途中結果をまだ毎回訳しています。") == .missing("途中結果をまだ毎回訳しています。"))
        #expect(StepCheck.verdict(from: "") == .unreadable)
        #expect(StepCheck.verdict(from: "確認しましたが、判断できません。") == .unreadable)
        #expect(StepCheck.verdict(from: "OKAY, but the listener is still missing") == .unreadable)
        #expect(StepCheck.verdict(from: "MISSING:") == .unreadable)
        #expect(StepCheck.missing(from: "判断できません") == nil)
    }
}
