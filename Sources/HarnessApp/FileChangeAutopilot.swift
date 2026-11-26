import Foundation
import HarnessCore

/// 「おまかせで作る」 (2026-11-10, the user: 「開発経験がないユーザーも君とのここでのやり取りみたいにパイプコーディングできる様に」):
/// one press writes the file, saves it, builds and tests it, and fixes what fails from the build errors, up to a limit,
/// then moves on to the next file of a plan. Building 14Translate's first file this way by hand took dozens of presses.
/// Every save keeps its Git restore point, so nothing done here is beyond undoing.
@MainActor
@Observable
final class FileChangeAutopilot {
    static let maximumRepairRounds = 6

    private(set) var isOn = false
    private(set) var repairRounds = 0
    var status: String?
    /// When a run ended (finished, stopped or gave up); the screen opened from the chat closes then (2026-11-11).
    private(set) var endedAt: Date?
    /// Where the steps that matter are told, plainly (the code chat; 2026-11-10).
    @ObservationIgnored var onReport: ((String) -> Void)?
    /// When a run ends: whether it ended well, and whether the person closed it (then nothing waiting should start).
    @ObservationIgnored var onEnded: ((_ good: Bool, _ closed: Bool) -> Void)?
    private(set) var savedFiles: [String] = []
    var lastApplied: FileChangeProposal?
    /// Plans a request instead of repairing (two copies of the same work: one is taken out; 2026-11-18).
    @ObservationIgnored var onConsolidate: ((String) -> Void)?
    private var retriedUnchanged = false
    var planRetried = false
    /// Files of the plan whose change was checked against their step (once each; 2026-11-16).
    var stepChecked: [String: Int] = [:]
    /// Files saved although their step check gave no answer that could be read (2026-11-25 review: that was taken as OK).
    var stepUnverified: Set<String> = []
    var raisedTarget = false; @ObservationIgnored var validationRetried = false
    private var triedSecondWriter = false
    private var keptWriter: ModelSelection?
    /// The model to ask when the project's own gave nothing usable twice (the catalog's 「secondCoder」 role).
    @ObservationIgnored var secondWriterModel: (() -> ModelSelection?)? = { PurposeModelSettings().secondCoder }
    /// What to do once the project builds and passes its tests (a request from the chat waits for that; 2026-11-10).
    private var afterPassing: (() -> Void)?
    /// Files whose tests failed before a request and could not be fixed; their failures no longer hold anything back. Kept
    /// per project for the requests that follow (each opens its own screen), until the project passes in full.
    /// The last failed check's repair plan: starting a repair selects the file, which clears the check's result.
    private var lastFailedPlan: BuildRepairPlan?
    /// Kept across launches (2026-11-12: after the Factory was reinstalled, the set-aside tests were tried six times again).
    private var rootPath = ""
    var setAsideFiles: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "harness.autopilot.setAside." + rootPath) ?? []) }
        set {
            let key = "harness.autopilot.setAside." + rootPath
            newValue.isEmpty ? UserDefaults.standard.removeObject(forKey: key) : UserDefaults.standard.set(newValue.sorted(), forKey: key)
        }
    }

    func start(_ session: FileChangeSession) {
        guard session.canAskAI else {
            return finish("おまかせを始められませんでした(作るファイルか、作ってほしいことが決まっていません)。もう一度「続けて」と書いてください。")
        }
        isOn = true
        rootPath = session.rootPath
        repairRounds = 0
        retriedUnchanged = false; triedSecondWriter = false; keptWriter = nil
        savedFiles = []; lastApplied = nil
        stepChecked = [:]; stepUnverified = []
        raisedTarget = false
        status = "案を作っています…"
        session.askAI()
    }

    /// A request from the chat: first the project as it is must build and pass, fixed if not, then `then` runs.
    func checkFirst(_ session: FileChangeSession, request: String = "", onComplete: @escaping @MainActor @Sendable (ProjectValidationReport) -> Void,
                    then next: @escaping () -> Void) {
        isOn = true
        rootPath = session.rootPath
        Self.keepTestsRequested(request, root: rootPath); if Self.testsRequested(root: rootPath) { setAsideFiles = [] }
        repairRounds = 0
        retriedUnchanged = false; triedSecondWriter = false; keptWriter = nil
        savedFiles = []; lastApplied = nil
        stepChecked = [:]; stepUnverified = []
        raisedTarget = false
        afterPassing = next
        lastFailedPlan = nil
        status = "まず今のプロジェクトを確かめています…"
        onReport?(Self.beforeCheckNote() + "まず今のプロジェクトがビルドとテストに通るかを確かめます。")
        watchValidation(session); session.validation.start(onComplete: onComplete)
    }

    /// The screen was closed while it was working (2026-11-11: the user moved to the chat and the run ended unsaid).
    func interrupted() {
        guard isOn else { return }
        finish("画面を閉じたので、途中で止めました。ここまでの変更は保存されています。「続けて」と書けば、続きから進めます。", closed: true)
    }

    func stop(_ session: FileChangeSession) {
        afterPassing = nil
        session.stopAll()
        // Stopped by the person: the requests waiting after this one stop too (2026-11-16: 「止める」 went straight on to
        // the next request of the split message).
        finish("止めました。ここまでの変更は保存されています。", closed: true)
    }

    /// The model finished: save its proposal, or stop if it gave none.
    func generationFinished(_ session: FileChangeSession, apply: @escaping () -> Void) {
        guard isOn else { return }
        guard session.proposal != nil, !session.isApplied else {
            // The model gave the file back unchanged: ask once more, plainly (2026-11-10, SpeechListener's concurrency errors).
            // Also an answer that could not be read, or ran into blanks.
            let retriable = ["変更内容がありません", "読み取れませんでした", "空白の繰り返し"]
            if repairRounds < Self.maximumRepairRounds, !retriedUnchanged,
               let message = session.errorMessage, retriable.contains(where: message.contains) {
                retriedUnchanged = true
                repairRounds += 1
                if !session.aiInstruction.contains("前回の案は") {
                    session.aiInstruction += "\n前回の案は使えませんでした(変更がない、または形式が崩れていた)。ファイル全体を、空白を続けずに最後まで書いてください。"
                }
                status = "もう一度直しています(\(repairRounds)/\(Self.maximumRepairRounds) 回目)…"
                session.askAI()
                return
            }
            // A file of the plan that already is as asked: kept, and the plan goes on (2026-11-11: 14Translate's screen already
            // had what 「続けて」 planned, and the run stopped at 「変更内容がありません」).
            // Not in a repair: a file the build still fails on is not 「already done」 (2026-11-11: it was, and the run said so).
            // Not after the step check found something missing: an unchanged file then is the writer giving up, not the step
            // being done (2026-11-16: the check named the missing change, the rewrite came back unchanged, and the run said
            // 「頼まれたことは、すでにできていました」).
            if let missing = StepCheck.missingNoted(in: session.aiInstruction), session.errorMessage?.contains("変更内容がありません") == true {
                let name = (session.selectedPath.map { ($0 as NSString).lastPathComponent }) ?? "ファイル"
                return finish("\(name) に、頼まれたことの一部を入れられませんでした(\(missing.prefix(160)))。"
                    + "「続けて」と書けば、作り方を変えてもう一度試します。")
            }
            if session.errorMessage?.contains("変更内容がありません") == true, session.artifactPlan != nil, session.repairProgress == nil,
               !session.aiInstruction.hasPrefix(BuildRepairTarget.instructionOpening), let path = session.selectedPath {
                onReport?("\((path as NSString).lastPathComponent) はすでに頼まれた形になっていたので、そのままにしました。")
                Task { await alreadyDone(session) }
                return
            }
            // A second writer, once: another local model reads the same request (switched to by itself, one model in
            // memory at a time on the same server).
            if session.secondWriter == nil, !triedSecondWriter, let second = secondWriterModel?(), second != session.model,
               let message = session.errorMessage, retriable.contains(where: message.contains) {
                triedSecondWriter = true
                session.secondWriter = second
                onReport?("いつものモデルでは直せなかったので、別のモデル(\(second.displayName))に頼み直します。")
                status = "別のモデルで直しています…"
                session.askAI()
                return
            }
            session.secondWriter = nil
            // A test repair both writers left unchanged, while a test request runs: once more, told that nothing changed
            // (2026-11-17: the reading tests' repair ended after one round with 「変更内容がありません」).
            if Self.testsRequested(root: rootPath), session.aiInstruction.hasPrefix(BuildRepairTarget.instructionOpening),
               repairRounds < Self.maximumRepairRounds {
                repairRounds += 1; triedSecondWriter = false
                if !session.aiInstruction.contains(Self.unchangedNudge) { session.aiInstruction += Self.unchangedNudge }
                session.askAI(); return
            }
            if setAsideOldTests(session) { return }
            // The request's files are written and a repair gave nothing: 「続けて」 goes on with the repair (2026-11-16).
            if afterPassing == nil, !savedFiles.isEmpty, session.aiInstruction.hasPrefix(BuildRepairTarget.instructionOpening) {
                Self.setPendingRepair(true, root: rootPath)
                return finish("案を作れませんでした" + (session.errorMessage.map { "(\($0))" } ?? "") + "。" + Self.leftoverErrors(lastFailedPlan)
                    + "\n「続けて」と書けば、作ったものはそのままで、このエラーの直しを続けます。")
            }
            return finish("案を作れませんでした" + (session.errorMessage.map { "(\($0))" } ?? "") + "。")
        }
        retriedUnchanged = false
        // The second writer, once it has given a usable change, writes the rest of this run (2026-11-12: it fixed one of
        // four tests where the first gave nothing, then the first gave nothing again).
        if let second = session.secondWriter { keptWriter = second }
        session.secondWriter = nil
        status = "保存して確かめています…"
        guard needsStepCheck(session) else { return apply() }
        Task { await checkStepThenApply(session, apply: apply) }
    }

    func alreadyDone(_ session: FileChangeSession) async {
        guard await session.skipToNextArtifactTarget() else {
            // Files this run saved are checked before anything is said to pass (2026-11-11: 「通っています」 was said with a
            // compile error left in the file saved just before).
            if !savedFiles.isEmpty {
                status = "保存したファイルをビルドとテストで確かめています…"
                session.validation.start(onComplete: { _ in })
                return
            }
            return finish("頼まれたことは、すでにできていました(ビルドとテストは通っています)。")
        }
        retriedUnchanged = false
        status = "次のファイル(\(session.selectedPath ?? session.newFileRelativePath))を作っています…"
        session.askAI()
    }

    /// A file was saved: in a plan of several files the next one comes before any check.
    func applied(_ session: FileChangeSession) {
        guard isOn else { return }
        if let path = session.appliedChange?.proposal.relativePath {
            savedFiles.append(path); lastApplied = session.appliedChange?.proposal
            onReport?("\((path as NSString).lastPathComponent) を\(repairRounds == 0 ? "作りました" : "直しました")。")
        }
        if session.canContinueArtifactPlan {
            Task {
                await session.continueToNextArtifactTarget()
                status = "次のファイル(\(session.selectedPath ?? session.newFileRelativePath))を作っています…"
                session.askAI()
            }
        }
    }

    /// The build and tests finished.
    func validationFinished(_ session: FileChangeSession) async {
        guard isOn, let report = session.validation.report else { return }
        if report.succeeded { setAsideFiles = [] }
        let passed = report.succeeded || onlySetAsideFail(session)
        // A test file this run saved that checks nothing is not a pass (2026-11-10: a model asked not to fake a final class
        // emptied the test instead, and the project 「passed」).
        if passed, let empty = Self.emptyTests(savedFiles, root: session.rootPath).first {
            return finish("ビルドは通りましたが、\((empty as NSString).lastPathComponent) のテストが何も確かめていません。"
                + "何を確かめてほしいか(例: 初めは止まっている、履歴は新しい順など)を書いて、もう一度頼んでください。")
        }
        // What a passing build cannot show (2026-11-11): a model file the code names and the project lacks, and callbacks
        // that stop the app on the iPhone.
        let root = URL(fileURLWithPath: session.rootPath)
        if passed, repairRounds < Self.maximumRepairRounds,
           case let missing = MissingResourceCheck.diagnostics(rootURL: root) + BackgroundCallbackCheck.diagnostics(rootURL: root)
               + DuplicateLiteralKeyCheck.diagnostics(rootURL: root) + BundledPromptCheck.diagnostics(rootURL: root)
               + UnfinishedCodeCheck.diagnostics(rootURL: root, savedFiles: savedFiles,
                                                 before: { [rootPath = session.rootPath] in UnfinishedCodeCheck.committed($0, root: rootPath) }),
           let first = missing.first {
            repairRounds += 1
            let name = (first.relativePath as NSString).lastPathComponent
            status = "iPhone で動かすと困る所を直しています(\(first.relativePath))…"
            onReport?("ビルドは通りましたが、iPhone で動かすと困る所が \(name) にあるので直しています。")
            await session.continueRepair(with: BuildRepairPlan(targets: [BuildRepairTarget(relativePath: first.relativePath,
                diagnostics: missing.filter { $0.relativePath == first.relativePath })], unresolvedErrorCount: 0))
            session.askAI()
            return
        }
        // 「続けて」 after a run that left only errors: once they are fixed, the request is done (not planned again).
        if passed, afterPassing != nil, Self.hasPendingRepair(root: rootPath) {
            afterPassing = nil
            return finish(verdict(fixedLeftover: true, report: report))
        }
        if passed, let next = afterPassing {
            afterPassing = nil
            isOn = false
            status = "ビルドとテストが通りました。頼まれたことに進みます…"
            onReport?(!report.succeeded ? "前からある所のテスト以外は通りました\(setAsideNote)。頼まれたことに進みます。"
                      : repairRounds == 0 ? "今のプロジェクトは通りました。頼まれたことに進みます。"
                      : "直して通るようになりました(修正 \(repairRounds) 回)。頼まれたことに進みます。")
            next()
            return
        }
        if passed {
            return finish(verdict(fixedLeftover: false, report: report))
        }
        lastFailedPlan = keepingBetter(session, previous: lastFailedPlan, new: session.validation.failureAnalysis?.repairPlan)
        // A newer iOS asked for by the code, and the person's iPhone has it: the project's minimum iOS goes up (2026-11-17).
        if let plan = lastFailedPlan, case let messages = plan.targets.flatMap({ $0.diagnostics.map(\.message) }),
           let version = DeploymentTargetRaise.required(messages), !raisedTarget,
           let old = DeploymentTargetRaise.raise(root: session.rootPath, to: version) {
            raisedTarget = true
            onReport?("新しい iOS の仕組みを使うので、プロジェクトの最低 iOS を \(old) から \(version) に上げました(つないでいる iPhone はそれ以上の版です)。もう一度確かめます。")
            status = "最低 iOS を上げて確かめ直しています…"
            session.validation.start(onComplete: { _ in })
            return
        }
        // Old tests set aside are not repaired again while something new fails (2026-11-13: a run whose change broke one
        // test spent its repairs on the reading tests set aside the day before).
        if let full = lastFailedPlan, case let fresh = full.targets.filter({ !setAsideFiles.contains($0.relativePath) }),
           !fresh.isEmpty, fresh.count < full.targets.count {
            lastFailedPlan = BuildRepairPlan(targets: fresh, unresolvedErrorCount: full.unresolvedErrorCount)
        }
        guard let plan = lastFailedPlan, !plan.targets.isEmpty else {
            // Said in plain words, without asking the person to pick files (2026-11-12, the user is not a developer).
            let reason = report.checks.first { !$0.succeeded }.flatMap { Self.plainReason($0.output) } ?? ""
            return finish("確かめたら通りませんでしたが、どこを直せばよいかを見つけられませんでした。" + reason
                + "様子を言葉で書いてもらえれば(例: 「〜すると止まる」)、それをもとに直します。")
        }
        if let consolidate = onConsolidate, let text = consolidationRequest(session, plan: plan) {
            afterPassing = nil; isOn = false; repairRounds = 0; consolidate(text); return }
        guard repairRounds < Self.maximumRepairRounds else {
            if setAsideOldTests(session) { return }
            // The request's own files are written: 「続けて」 fixes what is left rather than planning it again.
            if afterPassing == nil, !savedFiles.isEmpty || Self.hasPendingRepair(root: rootPath) {
                Self.setPendingRepair(true, root: rootPath)
            }
            return finish("\(Self.maximumRepairRounds) 回直しても通りませんでした。" + Self.leftoverErrors(lastFailedPlan)
                + "\n「続けて」と書けば、作ったものはそのままで、このエラーの直しを続けます。様子や直し方の指示を足してもかまいません。")
        }
        repairRounds += 1; if repairRounds == 1 { RepairHistory.shared.reset(root: rootPath) }
        status = "エラーを直しています(\(repairRounds)/\(Self.maximumRepairRounds) 回目: \(plan.targets[0].relativePath))…"
        onReport?("確かめたら通らなかったので直しています(\(repairRounds) 回目、\((plan.targets[0].relativePath as NSString).lastPathComponent))。")
        await session.continueRepair(with: plan)
        session.secondWriter = keptWriter
        session.askAI()
    }

    /// Before the request, tests that keep failing do not keep the request from running (2026-11-12: 14Translate's three
    /// reading tests failed through every repair, and the person's three new requests never started). Only when the build
    /// itself works and only tests fail; those tests are named, in plain words, and left for later.
    private func setAsideOldTests(_ session: FileChangeSession) -> Bool {
        guard let next = afterPassing, let plan = session.validation.failureAnalysis?.repairPlan ?? lastFailedPlan,
              Self.onlyTestsFail(plan) else { return false }
        // A request about these very tests: its plan, which may change several files, is what fixes them (2026-11-18).
        if !Self.testsRequested(root: rootPath) { setAsideFiles = Set(plan.targets.map(\.relativePath)) }
        afterPassing = nil
        isOn = false; repairRounds = 0
        let names = plan.targets.map { ($0.relativePath as NSString).lastPathComponent }.joined(separator: "、")
        onReport?(Self.setAsideMessage(names, requested: Self.testsRequested(root: rootPath)))
        next()
        return true
    }

    private func onlySetAsideFail(_ session: FileChangeSession) -> Bool {
        guard !setAsideFiles.isEmpty, let plan = session.validation.failureAnalysis?.repairPlan, !plan.targets.isEmpty,
              Self.onlyTestsFail(plan) else { return false }
        return Set(plan.targets.map(\.relativePath)).isSubset(of: setAsideFiles)
    }

    private var setAsideNote: String {
        setAsideFiles.isEmpty ? "" : "(前からある " + setAsideFiles.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: "、")
            + " のテストは、まだ通らないままです)"
    }

    func endRun(_ message: String) { isOn = true; finish(message) }

    func finish(_ message: String, closed: Bool = false, good: Bool? = nil) {
        isOn = false
        endedAt = Date()
        // Stopped before the request itself (the project as it was did not pass): the requests waiting after it would stop
        // at the same place, so they wait for 「続けて」 instead (2026-11-12: four requests ended the same way in a minute).
        let blocked = afterPassing != nil
        let ended = good ?? (message.hasPrefix("できました") || message.hasPrefix("頼まれたことは、すでにできていました"))
        if ended { Self.setPendingRepair(false, root: rootPath) }
        defer { onEnded?(ended, closed || blocked) }
        afterPassing = nil
        status = message
        onReport?(message)
    }
}
