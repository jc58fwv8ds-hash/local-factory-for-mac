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
    private(set) var status: String?
    /// When a run ended (finished, stopped or gave up); the screen opened from the chat closes then (2026-11-11).
    private(set) var endedAt: Date?
    /// Where the steps that matter are told, plainly (the code chat; 2026-11-10).
    @ObservationIgnored var onReport: ((String) -> Void)?
    /// When a run ends: whether it ended well, and whether the person closed it (then nothing waiting should start).
    @ObservationIgnored var onEnded: ((_ good: Bool, _ closed: Bool) -> Void)?
    private(set) var savedFiles: [String] = []
    private var retriedUnchanged = false
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
        retriedUnchanged = false
        triedSecondWriter = false
        keptWriter = nil
        savedFiles = []
        status = "案を作っています…"
        session.askAI()
    }

    /// A request from the chat: first the project as it is must build and pass, fixed if not, then `then` runs
    /// (the order a person asked to 「続けて」 would take).
    func checkFirst(_ session: FileChangeSession, onComplete: @escaping @MainActor @Sendable (ProjectValidationReport) -> Void,
                    then next: @escaping () -> Void) {
        isOn = true
        repairRounds = 0
        retriedUnchanged = false
        triedSecondWriter = false
        keptWriter = nil
        savedFiles = []
        afterPassing = next
        rootPath = session.rootPath
        lastFailedPlan = nil
        status = "まず今のプロジェクトを確かめています…"
        onReport?("まず今のプロジェクトがビルドとテストに通るかを確かめます。")
        session.validation.start(onComplete: onComplete)
    }

    /// The screen was closed while it was working (2026-11-11: the user moved to the chat and the run ended unsaid).
    func interrupted() {
        guard isOn else { return }
        finish("画面を閉じたので、途中で止めました。ここまでの変更は保存されています。「続けて」と書けば、続きから進めます。", closed: true)
    }

    func stop(_ session: FileChangeSession) {
        afterPassing = nil
        session.stopAll()
        finish("止めました。ここまでの変更は保存されています。")
    }

    /// The model finished: save its proposal, or stop if it gave none.
    func generationFinished(_ session: FileChangeSession, apply: () -> Void) {
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
            if setAsideOldTests(session) { return }
            return finish("案を作れませんでした" + (session.errorMessage.map { "(\($0))" } ?? "") + "。")
        }
        retriedUnchanged = false
        // The second writer, once it has given a usable change, writes the rest of this run (2026-11-12: it fixed one of
        // four tests where the first gave nothing, then the first gave nothing again).
        if let second = session.secondWriter { keptWriter = second }
        session.secondWriter = nil
        status = "保存して確かめています…"
        apply()
    }

    private func alreadyDone(_ session: FileChangeSession) async {
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
            savedFiles.append(path)
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
               + DuplicateLiteralKeyCheck.diagnostics(rootURL: root),
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
            return finish("できました。ビルドとテストに合格しました(保存 \(savedFiles.count) 件、修正 \(repairRounds) 回)。" + setAsideNote)
        }
        lastFailedPlan = session.validation.failureAnalysis?.repairPlan
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
        guard repairRounds < Self.maximumRepairRounds else {
            if setAsideOldTests(session) { return }
            return finish("\(Self.maximumRepairRounds) 回直しても通りませんでした。下のエラーを見て、指示を足してからもう一度お願いします。")
        }
        repairRounds += 1
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
        setAsideFiles = Set(plan.targets.map(\.relativePath))
        afterPassing = nil
        isOn = false
        repairRounds = 0
        let names = plan.targets.map { ($0.relativePath as NSString).lastPathComponent }.joined(separator: "、")
        onReport?("前からある \(names) のテストは、直せないまま残っています。アプリは動く状態なので、先に頼まれたことに進みます。")
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

    /// A failure that is only tests failing, not code that does not build.
    nonisolated static func onlyTestsFail(_ plan: BuildRepairPlan) -> Bool {
        !plan.targets.isEmpty && plan.targets.allSatisfy { target in
            !target.diagnostics.isEmpty && target.diagnostics.allSatisfy { $0.message.hasPrefix("テスト") }
        }
    }

    /// What stopped a check, in everyday words, when it can be told.
    static func plainReason(_ output: String) -> String? {
        if output.contains("Fatal error:") || output.contains("crashed") { return "テストの途中でアプリが落ちました。" }
        if output.contains("CompileAssetCatalog") { return "アイコンなどの素材をまとめる所で失敗しました。" }
        if output.contains("error:") { return "ビルドでエラーが出ました。" }
        return nil
    }

    /// The saved test files with no expectation in them.
    static func emptyTests(_ paths: [String], root: String) -> [String] {
        paths.filter { $0.contains("Tests/") && $0.hasSuffix(".swift") }.filter { path in
            guard let text = try? String(contentsOfFile: (root as NSString).appendingPathComponent(path), encoding: .utf8) else { return false }
            return text.range(of: #"#expect|#require|XCTAssert|XCTUnwrap|XCTFail"#, options: .regularExpression) == nil
        }
    }

    private func finish(_ message: String, closed: Bool = false) {
        isOn = false
        endedAt = Date()
        // Stopped before the request itself (the project as it was did not pass): the requests waiting after it would stop
        // at the same place, so they wait for 「続けて」 instead (2026-11-12: four requests ended the same way in a minute).
        let blocked = afterPassing != nil
        defer { onEnded?(message.hasPrefix("できました") || message.hasPrefix("頼まれたことは、すでにできていました"), closed || blocked) }
        afterPassing = nil
        status = message
        onReport?(message)
    }
}
