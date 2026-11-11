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
    /// Where the steps that matter are told, plainly (the code chat; 2026-11-10).
    @ObservationIgnored var onReport: ((String) -> Void)?
    private(set) var savedFiles: [String] = []
    private var retriedUnchanged = false
    /// What to do once the project builds and passes its tests (a request from the chat waits for that; 2026-11-10).
    private var afterPassing: (() -> Void)?

    func start(_ session: FileChangeSession) {
        guard session.canAskAI else { return }
        isOn = true
        repairRounds = 0
        retriedUnchanged = false
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
        savedFiles = []
        afterPassing = next
        status = "まず今のプロジェクトを確かめています…"
        onReport?("まず今のプロジェクトがビルドとテストに通るかを確かめます。")
        session.validation.start(onComplete: onComplete)
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
            return finish("案を作れませんでした" + (session.errorMessage.map { "(\($0))" } ?? "") + "。")
        }
        retriedUnchanged = false
        status = "保存して確かめています…"
        apply()
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
        // A test file this run saved that checks nothing is not a pass (2026-11-10: a model asked not to fake a final class
        // emptied the test instead, and the project 「passed」).
        if report.succeeded, let empty = Self.emptyTests(savedFiles, root: session.rootPath).first {
            return finish("ビルドは通りましたが、\((empty as NSString).lastPathComponent) のテストが何も確かめていません。"
                + "何を確かめてほしいか(例: 初めは止まっている、履歴は新しい順など)を書いて、もう一度頼んでください。")
        }
        if report.succeeded, let next = afterPassing {
            afterPassing = nil
            isOn = false
            status = "ビルドとテストが通りました。頼まれたことに進みます…"
            onReport?(repairRounds == 0 ? "今のプロジェクトは通りました。頼まれたことに進みます。"
                      : "直して通るようになりました(修正 \(repairRounds) 回)。頼まれたことに進みます。")
            next()
            return
        }
        if report.succeeded {
            return finish("できました。ビルドとテストに合格しました(保存 \(savedFiles.count) 件、修正 \(repairRounds) 回)。")
        }
        guard let plan = session.validation.failureAnalysis?.repairPlan, !plan.targets.isEmpty else {
            return finish("テストかビルドが通りませんでしたが、どのファイルを直すかは自動では決められませんでした。下の結果で"
                + "失敗したテストと理由を見て、直すファイルを左の一覧から選び、直してほしいことを書いてもう一度押してください。")
        }
        guard repairRounds < Self.maximumRepairRounds else {
            return finish("\(Self.maximumRepairRounds) 回直しても通りませんでした。下のエラーを見て、指示を足してからもう一度お願いします。")
        }
        repairRounds += 1
        status = "エラーを直しています(\(repairRounds)/\(Self.maximumRepairRounds) 回目: \(plan.targets[0].relativePath))…"
        onReport?("確かめたら通らなかったので直しています(\(repairRounds) 回目、\((plan.targets[0].relativePath as NSString).lastPathComponent))。")
        await session.continueRepair(with: plan)
        session.askAI()
    }

    /// The saved test files with no expectation in them.
    static func emptyTests(_ paths: [String], root: String) -> [String] {
        paths.filter { $0.contains("Tests/") && $0.hasSuffix(".swift") }.filter { path in
            guard let text = try? String(contentsOfFile: (root as NSString).appendingPathComponent(path), encoding: .utf8) else { return false }
            return text.range(of: #"#expect|#require|XCTAssert|XCTUnwrap|XCTFail"#, options: .regularExpression) == nil
        }
    }

    private func finish(_ message: String) {
        isOn = false
        afterPassing = nil
        status = message
        onReport?(message)
    }
}
