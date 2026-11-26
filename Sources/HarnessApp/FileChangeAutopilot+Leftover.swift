import Foundation
import HarnessCore

/// What a run that gave up leaves behind (2026-11-16: 14Translate's glossary run stopped with 「下のエラーを見て」 and no error
/// anywhere on the screen, and 「続けて」 then planned the whole request again, rewrote four nearly-done files and broke
/// them anew).
extension FileChangeAutopilot {
    /// The errors still left, one line each, for the chat.
    nonisolated static func leftoverErrors(_ plan: BuildRepairPlan?) -> String {
        let lines = (plan?.targets ?? []).flatMap { target in
            target.diagnostics.prefix(2).map { diagnostic in
                let name = (target.relativePath as NSString).lastPathComponent
                return "・\(name)" + (diagnostic.line.map { " \($0) 行目" } ?? "") + ": " + diagnostic.message
            }
        }.prefix(5)
        return lines.isEmpty ? "" : "\n残っているエラー:\n" + lines.joined(separator: "\n")
    }

    /// A request whose files were written and only its errors are left: 「続けて」 goes on fixing them instead of planning
    /// the request again. Kept per project folder across launches.
    nonisolated static func pendingRepairKey(_ root: String) -> String { "harness.autopilot.pendingRepair." + root }

    nonisolated static func setPendingRepair(_ pending: Bool, root: String) {
        let key = pendingRepairKey(root)
        pending ? UserDefaults.standard.set(true, forKey: key) : UserDefaults.standard.removeObject(forKey: key)
    }

    nonisolated static func hasPendingRepair(root: String) -> Bool {
        UserDefaults.standard.bool(forKey: pendingRepairKey(root))
    }

    /// Old Simulator apps go to the Trash before the check, said in the chat (2026-11-17, the user: 「次の工程で足しておいて」).
    nonisolated static func beforeCheckNote() -> String {
        SimulatorLeftovers.note(movedBytes: SimulatorLeftovers.moveToTrash()).map { $0 + "\n" } ?? ""
    }

    /// A request about the tests themselves: the tests set aside earlier are what it is about, so they are fixed first,
    /// not stepped over (2026-11-17, the user: 「前から残っていることも含め直ってから iPhone に入れよう」; asked to make the old
    /// reading, translation and glossary tests pass, the run set them aside again, said 「すでに頼まれた形」 and never looked).
    nonisolated static func asksAboutTests(_ request: String) -> Bool {
        request.range(of: #"テスト|(?i)\btests?\b"#, options: .regularExpression) != nil
    }

    /// While such a request runs, failing tests are not set aside again (2026-11-17: cleared before the check, the old tests
    /// were set aside anew after one repair round, and the request went on to write number reading into the translator).
    nonisolated static func setTestsRequested(_ requested: Bool, root: String) {
        let key = "harness.autopilot.testsRequested." + root
        requested ? UserDefaults.standard.set(true, forKey: key) : UserDefaults.standard.removeObject(forKey: key)
    }

    /// A request about tests sets it; another real request clears it; 「続けて」 and the like leave it as it was.
    nonisolated static func keepTestsRequested(_ request: String, root: String) {
        let real = request.trimmingCharacters(in: .whitespacesAndNewlines).count > 12
        if real { UserDefaults.standard.set(request, forKey: "harness.autopilot.request." + root) }
        if asksAboutTests(request) { setTestsRequested(true, root: root) }
        else if real { setTestsRequested(false, root: root) }
    }

    /// The person's request now running, given with the repairs made before its plan (2026-11-18: told 「千の前が3のときだけ
    /// 『ぜん』と濁る」, the repairs that ran first saw only the failing tests, and the rule never reached them).
    nonisolated static func currentRequest(root: String) -> String? {
        UserDefaults.standard.string(forKey: "harness.autopilot.request." + root)
    }

    nonisolated static func testsRequested(root: String) -> Bool {
        UserDefaults.standard.bool(forKey: "harness.autopilot.testsRequested." + root)
    }

    /// A check that stops on an error: once more, then the run ends saying so (2026-11-19: it waited in silence).
    func watchValidation(_ session: FileChangeSession) {
        validationRetried = false
        session.validation.onFailure = { [weak self, weak session] reason in
            guard let self, let session, self.isOn else { return }
            guard self.validationRetried else {
                self.validationRetried = true
                self.onReport?("ビルドとテストの確かめが途中で止まりました(\(reason.prefix(80)))。もう一度確かめます。")
                return session.validation.retry()
            }
            self.endRun("ビルドとテストの確かめが、2 回続けて途中で止まりました(\(reason.prefix(80)))。「続けて」と書けば、もう一度試します。")
        }
    }

    /// The request's plan could not be made: once more, then the run ends saying why.
    func planFailed(_ error: String, retry: () -> Void) {
        guard !planRetried else {
            planRetried = false
            return endRun("計画を作れませんでした(\(error))。もう一度「続けて」と書くか、頼み方を変えて送ってください。")
        }
        planRetried = true
        onReport?("計画を作れなかったので(\(error))、もう一度作ります。")
        retry()
    }

    /// A file of the request's plan, not a repair, not yet checked against its step.
    func needsStepCheck(_ session: FileChangeSession) -> Bool {
        guard session.artifactPlan?.currentTarget != nil, session.repairProgress == nil,
              !session.aiInstruction.hasPrefix(BuildRepairTarget.instructionOpening),
              let path = session.proposal?.relativePath, stepChecked[path, default: 0] < StepCheck.maximumChecks else { return false }
        return true
    }

    /// Asks whether the change does what the step asked; if not, the file is written once more with what was missing
    /// (2026-11-16: a step's real change was left out and the run reported 「できました」).
    func checkStepThenApply(_ session: FileChangeSession, apply: @escaping () -> Void) async {
        guard let proposal = session.proposal, let step = session.artifactPlan?.currentTarget?.instruction,
              let model = session.secondWriter ?? session.model else { return apply() }
        // Checked again after each rewrite (2026-11-18: only the first answer was checked; the rewrite after 「MISSING」 was
        // saved unchecked, still without the change, and the run said ビルドとテストに合格しました).
        stepChecked[proposal.relativePath, default: 0] += 1
        let last = stepChecked[proposal.relativePath, default: 0] >= StepCheck.maximumChecks
        status = "頼まれたとおりの変更かを確かめています…"
        let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier,
                                       messages: [InferenceMessage(role: .user, content: StepCheck.request(
                                           step: step, path: proposal.relativePath, diff: StepCheck.diffText(proposal.diffLines),
                                           file: proposal.proposedContent))],
                                       maximumOutputTokens: 400, temperature: 0)
        var answer = ""
        do { for try await piece in await session.inferenceProvider.events(for: request) { answer += piece } } catch { answer = "" }
        guard isOn else { return apply() }
        let missing: String
        switch StepCheck.verdict(from: answer) {
        case .ok:
            stepUnverified.remove(proposal.relativePath)
            return apply()
        case .unreadable:
            // Not a pass (2026-11-25 review): the change is saved so the run can go on, and the end says it was not checked.
            stepUnverified.insert(proposal.relativePath)
            onReport?("\((proposal.relativePath as NSString).lastPathComponent) は、頼まれたとおりかを確かめる返事が読めませんでした。"
                + "確かめられないまま保存し、最後にそう伝えます。")
            return apply()
        case let .missing(text):
            stepUnverified.remove(proposal.relativePath)
            missing = text
        }
        let name = (proposal.relativePath as NSString).lastPathComponent
        if last {
            // One step that will not go in no longer holds back the others (2026-11-18: the listener's crash fix was saved,
            // a side step on another file failed three times, and the run stopped before the build, the tests and the
            // iPhone). The step is left as it was, the plan goes on, and the end says what was left out.
            guard session.canContinueArtifactPlan || !savedFiles.isEmpty else {
                return finish("\(name) に、頼まれたことの一部を入れられませんでした(\(missing.prefix(160)))。"
                    + "書き直しても入らなかったので、保存せずに止めました。「続けて」と書けば、もう一度試します。")
            }
            stepChecked[proposal.relativePath] = StepCheck.maximumChecks + 1
            onReport?("\(name) は、書き直しても頼まれたとおりにならなかったので、変えずに先へ進みます(\(missing.prefix(80)))。")
            session.proposal = nil
            return await alreadyDone(session)
        }
        onReport?("\(name) の案は、頼まれたことの一部をしていなかったので書き直します(\(missing.prefix(80)))。")
        session.aiInstruction += StepCheck.feedback(missing)
        session.proposal = nil
        status = "足りない所を足して書き直しています…"
        session.askAI()
    }

    /// What stopped a check, in everyday words, when it can be told (2026-11-17: a full disk was told as an asset failure).
    nonisolated static func plainReason(_ output: String) -> String? {
        if output.contains("No space left on device") { return "この Mac のディスクの空きがなくなり、ビルドの途中のファイルを書けませんでした。いらないものを消すか、ゴミ箱を空にしてから「続けて」と書いてください。" }
        if output.contains("Fatal error:") || output.contains("crashed") { return "テストの途中でアプリが落ちました。" }
        if output.contains("CompileAssetCatalog") { return "アイコンなどの素材をまとめる所で失敗しました。" }
        if output.contains("error:") { return "ビルドでエラーが出ました。" }
        return nil
    }

    nonisolated static let unchangedNudge = "\n前の案はファイルを変えていませんでした。テストが期待する結果(上のエラーの「→」の左と右)を見て、それを返すように関数の中身を実際に書き換えてください。"

    /// A repair that breaks a passing test without fixing more than it breaks is undone, and the next repair is told what it broke (2026-11-18:
    /// the reading file went back and forth all night; one repair fixed 「1,000個」 and broke 「3,500円」, the next the reverse).
    func keepingBetter(_ session: FileChangeSession, previous: BuildRepairPlan?, new: BuildRepairPlan?) -> BuildRepairPlan? {
        // Compared with the whole of the last kept check (2026-11-18: the kept plan had the set-aside reading file taken out,
        // so its failing test looked newly broken and three good translator repairs were undone).
        let root = session.rootPath
        if let reverted = revertingBrokenShape(session, previous: previous, new: new) { return reverted }
        defer { if let new, lastApplied != nil || previous == nil { RepairHistory.shared.setLastFailing(Self.failingTests(new), root: root) } }
        guard let previous, let new, session.aiInstruction.hasPrefix(BuildRepairTarget.instructionOpening),
              case let before = RepairHistory.shared.lastFailing(root: root) ?? Self.failingTests(previous), case let after = Self.failingTests(new),
              !before.isEmpty, case let broken = after.subtracting(before), !broken.isEmpty, after.count >= before.count,
              let applied = lastApplied ?? session.appliedChange?.proposal,
              (try? applied.originalContent.write(to: URL(fileURLWithPath: session.rootPath).appendingPathComponent(applied.relativePath),
                                                  atomically: true, encoding: .utf8)) != nil else { return new }
        lastApplied = nil
        onReport?("\((applied.relativePath as NSString).lastPathComponent) の直しで、通っていたテスト(\(broken.sorted().joined(separator: "、")))が通らなくなり、全体でもよくならなかったので、その直しを戻しました。")
        _ = RepairHistory.shared.remind(root: session.rootPath, path: applied.relativePath,
                                       instruction: "前の案は、それまで通っていた次のテストを壊したので戻しました: " + broken.sorted().joined(separator: "、"))
        return previous
    }

    /// A repair that left the file it rewrote unreadable to the compiler (braces out of balance, a declaration cut in
    /// two), where the check before had no such error there: undone, and the next round starts from the file as it was
    /// (2026-11-23: six rounds on 14Translate's 1,000-line controller each built on the last broken rewrite and ended on
    /// 「Extraneous '}' at top level」).
    func revertingBrokenShape(_ session: FileChangeSession, previous: BuildRepairPlan?, new: BuildRepairPlan?) -> BuildRepairPlan? {
        guard let previous, let new, session.aiInstruction.hasPrefix(BuildRepairTarget.instructionOpening),
              let applied = lastApplied ?? session.appliedChange?.proposal,
              case let broken = Self.shapeErrors(new, path: applied.relativePath), !broken.isEmpty,
              Self.shapeErrors(previous, path: applied.relativePath).isEmpty,
              (try? applied.originalContent.write(to: URL(fileURLWithPath: session.rootPath).appendingPathComponent(applied.relativePath),
                                                  atomically: true, encoding: .utf8)) != nil else { return nil }
        lastApplied = nil
        onReport?("\((applied.relativePath as NSString).lastPathComponent) の直しで、ファイルの形が崩れた(かっこの数が合わないなど)ので、その直しを戻しました。")
        _ = RepairHistory.shared.remind(root: session.rootPath, path: applied.relativePath,
                                       instruction: "前の案はファイルの形を崩した(" + broken.prefix(2).joined(separator: "、")
                                           + ")ので戻しました。変える関数だけを、開きかっこと閉じかっこの数を合わせて書いてください。")
        return previous
    }

    nonisolated static let shapeErrorMarks = ["Extraneous '}'", "expected '}'", "expected declaration", "consecutive declarations",
                                              "unexpected '}'", "expected expression", "top level"]

    /// The compiler's errors about the file's shape, not its meaning, in one file.
    nonisolated static func shapeErrors(_ plan: BuildRepairPlan, path: String) -> [String] {
        plan.targets.flatMap(\.diagnostics).filter { $0.relativePath == path }.map(\.message)
            .filter { message in shapeErrorMarks.contains { message.contains($0) } }
    }

    /// The failing tests of a check, by name.
    nonisolated static func failingTests(_ plan: BuildRepairPlan) -> Set<String> {
        Set(plan.targets.flatMap(\.diagnostics).compactMap { diagnostic in
            diagnostic.message.range(of: #"^テスト \w+"#, options: .regularExpression).map { String(diagnostic.message[$0]) }
        })
    }

    nonisolated static func setAsideMessage(_ names: String, requested: Bool) -> String {
        requested ? "\(names) のテストは、一つずつの直しでは通りませんでした。頼まれたことの計画を立てて、まとめて直します。"
            : "前からある \(names) のテストは、直せないまま残っています。アプリは動く状態なので、先に頼まれたことに進みます。"
    }

    /// Two copies of the same work, one passing and one failing: the request that takes the failing copy out, once per
    /// project and copy (2026-11-18, the user: 「ファクトリーが自律的に同様の不具合に対応できるように」).
    func consolidationRequest(_ session: FileChangeSession, plan: BuildRepairPlan) -> String? {
        guard Self.onlyTestsFail(plan) else { return nil }
        let duplicates = DuplicateTests.find(diagnostics: plan.targets.flatMap(\.diagnostics), rootURL: URL(fileURLWithPath: session.rootPath))
        let key = "harness.autopilot.consolidated." + session.rootPath + "|" + duplicates.map { $0.testFile + "#" + $0.testName }.joined(separator: ",")
        guard !duplicates.isEmpty, !UserDefaults.standard.bool(forKey: key) else { return nil }
        UserDefaults.standard.set(true, forKey: key)
        onReport?("通らないテストは、ほかのテストがすでに確かめていて通っている内容と同じでした(同じ処理が二か所にあります)。"
            + "直し続けるのをやめ、一か所にまとめます。")
        return duplicates.map(\.request).joined(separator: "\n")
    }

    /// The end of a run that went through, told as this run's change apart from failures that were there before it
    /// (2026-11-25 review: 「ビルドとテストに合格しました」 was said with set-aside tests still failing).
    func verdict(fixedLeftover: Bool, report: ProjectValidationReport) -> RunVerdict {
        let name: (String) -> String = { ($0 as NSString).lastPathComponent }
        return RunVerdict(saved: savedFiles.count, repairRounds: repairRounds,
                          stillFailingBefore: report.succeeded ? [] : setAsideFiles.map(name),
                          leftOut: fixedLeftover ? [] : stepChecked.filter { $0.value > StepCheck.maximumChecks }.keys.map(name),
                          unverified: stepUnverified.filter { savedFiles.contains($0) }.map(name), fixedLeftover: fixedLeftover)
    }

    func finish(_ verdict: RunVerdict) {
        // A run whose own change went through still counts as ended well for what waits after it; the message says what is left.
        finish(verdict.message, good: true)
    }

    /// A failure that is only tests failing, not code that does not build.
    nonisolated static func onlyTestsFail(_ plan: BuildRepairPlan) -> Bool {
        !plan.targets.isEmpty && plan.targets.allSatisfy { target in
            !target.diagnostics.isEmpty && target.diagnostics.allSatisfy { $0.message.hasPrefix("テスト") }
        }
    }
    /// The saved test files with no expectation in them.
    static func emptyTests(_ paths: [String], root: String) -> [String] {
        paths.filter { $0.contains("Tests/") && $0.hasSuffix(".swift") }.filter { path in
            guard let text = try? String(contentsOfFile: (root as NSString).appendingPathComponent(path), encoding: .utf8) else { return false }
            return text.range(of: #"#expect|#require|XCTAssert|XCTUnwrap|XCTFail"#, options: .regularExpression) == nil
        }
    }
}
