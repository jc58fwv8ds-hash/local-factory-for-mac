import Foundation
import HarnessCore
import TaskOrchestrator

/// One code change asked for in the chat (2026-10-08): the orchestrated run over the whole package, shown as a card under
/// the user's message, applied or reverted from the card. Nothing touches the project before "適用する".
@MainActor
@Observable
final class ChatChange: Identifiable {
    enum Status: Equatable {
        case running
        case ready
        case applied
        case failed(String)
        case discarded
    }

    let id: UUID              // the user message that asked for the change
    let instruction: String
    var status: Status = .running
    var proposals: [FileChangeProposal] = []
    /// Reasons to look closely (要確認), from signals that predicted false successes in the measured suites.
    var cautions: [String] = []
    /// Concrete cases for the user to confirm (ExampleCheckStage): measured results on the final code and before it.
    var examples: [ChatExample] = []
    /// True while the example check and the examiner run after the card is shown.
    var isChecking = false
    /// The previous proposal's cases answered 違う: run again on this one and offered as a protected test.
    var seeds: [ChatExample] = []
    var runRecord: URL?
    @ObservationIgnored var applied: [(FileChangeProposal, GitFileCheckpoint?)] = []

    init(id: UUID, instruction: String) {
        self.id = id
        self.instruction = instruction
    }
}

/// One case shown as "この動きで合っていますか": the situation and value in the user's words, the measured result after the
/// change (and before it, when the old code could run it), and other readings of the request as follow-up instructions.
struct ChatExample: Identifiable, Equatable {
    enum Answer: Equatable { case right, wrong }
    let id = UUID()
    let situation: String
    let quantity: String
    let after: String
    let before: String?
    let alternatives: [String]
    /// How the case is run (Swift), kept so a 違う case can become a protected test after the correction (backlog #39).
    var setup: String = ""
    var expression: String = ""
    var answer: Answer?

    /// The follow-up instruction for one alternative, with the case it is about.
    func instruction(for alternative: String) -> String {
        "「\(situation)」のとき、\(quantity)は今の修正では \(after) です。\(alternative)"
    }
}

extension WorkspaceStore {
    /// A chat message can change code when the project is connected to a Swift package and the orchestrated run is on.
    var chatCodeChangeContext: (service: any OrchestratedEditing, root: String, model: ModelSelection)? {
        guard let service = chatOrchestratorOverride ?? OrchestratedRunSettings().service,
              let root = library.selectedRecord?.sourceLocation,
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("Package.swift").path),
              let model = project.selectedModel, model.runtime == .ollama || model.runtime == .backburner else { return nil }
        return (service, root, model)
    }

    /// Starts a code change from the chat. A follow-up while the previous change is still a proposal refines it: the
    /// previous instruction and the new one run together on the unchanged project, and the old card is withdrawn.
    func submitChatCodeChange(_ text: String, images: [InferenceImage]) -> Bool {
        startChatCodeChange(text, images: images, capturesCorrection: true)
    }

    /// `capturesCorrection`: a typed follow-up after 違う is remembered as a convention; a chosen alternative already was.
    private func startChatCodeChange(_ text: String, images: [InferenceImage], capturesCorrection: Bool) -> Bool {
        guard let context = chatCodeChangeContext else { return false }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        var instruction = cleaned
        var seeds: [ChatExample] = []
        if let previous = chatChanges.values.first(where: { $0.status == .ready }) {
            seeds = previous.examples.filter { $0.answer == .wrong && !$0.expression.isEmpty }
            // A typed correction after 違う on one of its examples is a convention of this project too.
            if capturesCorrection, let wrong = previous.examples.first(where: { $0.answer == .wrong }) {
                rememberConvention("「\(wrong.situation)」のとき: \(cleaned)")
            }
            previous.status = .discarded
            instruction = previous.instruction + "\n\n追加の指示: " + cleaned
        } else if let conventions = project.conventions, !conventions.isEmpty {
            instruction += "\n\nこのプロジェクトでこれまでに確かめた決まり(守ること):\n"
                + conventions.suffix(10).map { "- " + $0 }.joined(separator: "\n")
        }
        // The builder model reads text only: the text recognized in attached images goes with the instruction.
        let recognized = images.compactMap(\.recognizedText).map { transcript in
            "【添付画像「\(transcript.displayName)」の文字】\n" + transcript.lines.map(\.text).joined(separator: "\n")
        }
        if !recognized.isEmpty { instruction += "\n\n" + recognized.joined(separator: "\n\n") }

        let message = ConversationMessage(role: .user, content: cleaned, origin: .user,
                                          visualAttachments: images.map(\.descriptor))
        library.updateSelectedProject { $0.conversation.append(message) }
        persist()
        let change = ChatChange(id: message.id, instruction: instruction)
        change.seeds = seeds
        chatChanges[message.id] = change
        Task { await runChatChange(change, context: context) }
        return true
    }

    private func runChatChange(_ change: ChatChange,
                               context: (service: any OrchestratedEditing, root: String, model: ModelSelection)) async {
        do {
            let outcome = try await context.service.proposeEdit(rootPath: context.root, relativePath: "",
                                                                instruction: change.instruction, model: context.model)
            guard change.status == .running else { return }
            var proposals: [FileChangeProposal] = []
            for item in outcome.changes {
                if let original = item.original {
                    proposals.append(try await fileEditor.makeProposal(
                        document: EditableSourceDocument(relativePath: item.relativePath, content: original),
                        proposedContent: item.proposed))
                } else {
                    proposals.append(try await fileEditor.makeCreationProposal(rootPath: context.root,
                        relativePath: item.relativePath, proposedContent: item.proposed))
                }
            }
            change.proposals = proposals
            change.runRecord = outcome.runRecord
            change.cautions = Self.chatChangeCautions(record: outcome.runRecord, instruction: change.instruction)
            change.examples = Self.chatExamples(record: outcome.runRecord)
            change.status = .ready
            appendAssistantNote("修正案ができました(\(proposals.count) ファイル、テスト合格)。内容を確かめて「適用する」を押すと、プロジェクトに反映します。"
                + (change.cautions.isEmpty ? "" : " 要確認の点が \(change.cautions.count) つあります。"))
            if var post = outcome.postCheck {
                // Every change is checked after its card is shown (2026-10-10).
                post.seeds = change.seeds.map { ["situation": $0.situation, "quantity": $0.quantity, "setup": $0.setup,
                                                 "expression": $0.expression] }
                change.isChecking = true
                let service = context.service
                let root = context.root
                Task {
                    let updated = await service.postChecks(post)
                    change.isChecking = false
                    guard let updated, change.status == .ready else { return }
                    change.cautions = Self.chatChangeCautions(record: updated, instruction: change.instruction)
                    change.examples = Self.chatExamples(record: updated)
                    await self.addAgreedTest(from: updated, to: change, root: root)
                }
            }
        } catch {
            guard change.status == .running else { return }
            // A refusal by the normal model is retried once with the catalog's fallback (code changes keep the normal
            // model otherwise).
            let settings = purposeSettings
            if ModelRefusal.looksLikeRefusal(error.localizedDescription),
               let fallback = settings.catalog.option(id: settings.catalog.codeRefusalFallback, for: .writing)?.selection,
               fallback != context.model {
                await runChatChange(change, context: (context.service, context.root, fallback))
                return
            }
            change.status = .failed(error.localizedDescription)
            appendAssistantNote("修正案を作れませんでした。プロジェクトは変更していません。\n\(error.localizedDescription)")
        }
    }

    /// The cases the user corrected, as a protected test file of the project, verified on the tested copy (backlog #39).
    func addAgreedTest(from record: URL, to change: ChatChange, root: String) async {
        let result = (try? JSONSerialization.jsonObject(with: Data(contentsOf: record))) as? [String: Any] ?? [:]
        guard let agreed = ((result["exampleCheck"] as? [String: Any])?["agreedTest"]) as? [String: String],
              let path = agreed["path"], let content = agreed["content"], change.status == .ready else { return }
        let existing = try? String(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(path), encoding: .utf8)
        let made: FileChangeProposal?
        if let existing {
            made = try? await fileEditor.makeProposal(document: EditableSourceDocument(relativePath: path, content: existing),
                                                      proposedContent: content)
        } else {
            made = try? await fileEditor.makeCreationProposal(rootPath: root, relativePath: path, proposedContent: content)
        }
        guard let made, change.status == .ready else { return }
        change.proposals.append(made)
        change.cautions.append("「違う」と答えた場面の正しい動きを、今後の修正で崩れないようにテスト(\(path))として一緒に追加します")
    }

    static func chatExamples(record: URL) -> [ChatExample] {
        let result = (try? JSONSerialization.jsonObject(with: Data(contentsOf: record))) as? [String: Any] ?? [:]
        let rows = ((result["exampleCheck"] as? [String: Any])?["examples"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let situation = row["situation"] as? String, let quantity = row["quantity"] as? String,
                  let after = row["after"] as? String else { return nil }
            return ChatExample(situation: situation, quantity: quantity, after: after, before: row["before"] as? String,
                               alternatives: row["alternatives"] as? [String] ?? [], setup: row["setup"] as? String ?? "",
                               expression: row["expression"] as? String ?? "")
        }
    }

    func answerExample(_ example: ChatExample, in change: ChatChange, _ answer: ChatExample.Answer) {
        guard let index = change.examples.firstIndex(where: { $0.id == example.id }) else { return }
        change.examples[index].answer = answer
    }

    /// A chosen alternative refines the pending proposal like a typed follow-up (the previous instruction runs again with it).
    @discardableResult
    func chooseAlternative(_ alternative: String, for example: ChatExample) -> Bool {
        rememberConvention("「\(example.situation)」のとき: \(alternative)")
        return startChatCodeChange(example.instruction(for: alternative), images: [], capturesCorrection: false)
    }

    func forgetConvention(_ convention: String) {
        library.updateSelectedProject { $0.conventions = ($0.conventions ?? []).filter { $0 != convention } }
        persist()
    }

    /// Keeps the 20 most recent conventions of the selected project, without duplicates.
    func rememberConvention(_ convention: String) {
        library.updateSelectedProject { project in
            var list = (project.conventions ?? []).filter { $0 != convention }
            list.append(convention)
            project.conventions = Array(list.suffix(20))
        }
        persist()
    }

    /// Applies every file of the change; if one fails, the files already applied are reverted (all or nothing).
    func applyChatChange(_ change: ChatChange) async {
        guard change.status == .ready, let root = library.selectedRecord?.sourceLocation else { return }
        change.applied = []
        do {
            for proposal in change.proposals {
                let checkpoint = try? await gitCheckpointProvider.create(rootPath: root, proposal: proposal)
                do {
                    try await fileEditor.apply(rootPath: root, proposal: proposal)
                } catch {
                    if let checkpoint { await gitCheckpointProvider.discard(checkpoint) }
                    throw error
                }
                change.applied.append((proposal, checkpoint))
            }
            change.status = .applied
            appendAssistantNote("適用しました(\(change.proposals.count) ファイル)。取り消すときはカードの「取り消す」を押してください。")
        } catch {
            let stuck = await revertApplied(change, root: root)
            if stuck.isEmpty {
                presentNotice("適用できませんでした。変更は元に戻しました: \(error.localizedDescription)", kind: .information)
            } else {
                // Never "元に戻しました" while a file is still changed: the card stays applied so 取り消す can retry them.
                change.status = .applied
                appendAssistantNote("適用できませんでした(\(error.localizedDescription))。次のファイルは元に戻せず、修正後のままです: "
                    + stuck.joined(separator: "、") + "。カードの「取り消す」でもう一度戻すか、ファイルを確かめてください。")
            }
        }
    }

    func revertChatChange(_ change: ChatChange) async {
        guard change.status == .applied, let root = library.selectedRecord?.sourceLocation else { return }
        let stuck = await revertApplied(change, root: root)
        guard stuck.isEmpty else {
            appendAssistantNote("一部を元に戻せませんでした。次のファイルは修正後のままです: " + stuck.joined(separator: "、")
                + "。もう一度「取り消す」を押すと、残りだけを戻します。")
            return
        }
        change.status = .ready
        appendAssistantNote("取り消しました。プロジェクトは修正前の状態です。")
    }

    func discardChatChange(_ change: ChatChange) {
        guard change.status == .ready || change.status == .running else { return }
        change.status = .discarded
    }

    /// Reverts the applied files in reverse order. Returns the files that could not be reverted ("path(理由)"); those stay in
    /// `change.applied` with their checkpoints, so a later 取り消す retries exactly them.
    private func revertApplied(_ change: ChatChange, root: String) async -> [String] {
        var stuck: [(FileChangeProposal, GitFileCheckpoint?)] = [], reasons: [String] = []
        for (proposal, checkpoint) in change.applied.reversed() {
            do {
                try await fileEditor.revert(rootPath: root, proposal: proposal)
                if let checkpoint { await gitCheckpointProvider.discard(checkpoint) }
            } catch {
                stuck.insert((proposal, checkpoint), at: 0)
                reasons.append("\(proposal.relativePath)(\(error.localizedDescription))")
            }
        }
        change.applied = stuck
        return reasons
    }

    func appendAssistantNote(_ text: String) {
        library.updateSelectedProject { $0.conversation.append(ConversationMessage(role: .assistant, content: text, origin: .localModel)) }
        persist()
    }

    /// 要確認 signals measured on 388 tests-passed runs (2026-10-08; overall false-success rate 22%): repaired before the
    /// tests passed 40%, 9+ mandatory clauses 91%, 4+ boundary words 38%, request over 250 characters 38%; plus the
    /// harness's own leftover and examiner findings.
    static func chatChangeCautions(record: URL, instruction: String) -> [String] {
        let result = (try? JSONSerialization.jsonObject(with: Data(contentsOf: record))) as? [String: Any] ?? [:]
        var cautions = RiskSignals.reasons(repaired: result["modelFirstPass"] as? String == "MODEL_FIRST_PASS_FAIL",
                                           mandatoryClauses: result["mandatoryClauseCount"] as? Int, objective: instruction)
        if let leftover = result["leftoverCheck"] as? [String: Any], let outcome = leftover["outcome"] as? String,
           !outcome.hasPrefix("applied"), let hits = leftover["hits"] as? [[String: Any]], let first = hits.first {
            cautions.append("置き換えた古い処理が \(first["file"] as? String ?? "ほかのファイル") にも残っている可能性があります")
        }
        if let examiner = result["examinerCheck"] as? [String: Any], let confirmed = examiner["confirmed"] as? [String],
           !confirmed.isEmpty, !((examiner["outcome"] as? String) ?? "").hasPrefix("applied") {
            // The concrete value (2026-10-09): one alarm in ten is still the examiner's own misreading, so the card shows what
            // to check in the user's words (BatchExaminerStage.plainExample), e.g. "売上99円をAとBで半分ずつ分ける → 各人の
            // 源泉徴収額が、依頼から計算すると「[5, 4]」、今回の修正では「[5, 5]」", and the user decides in seconds.
            let examples = (examiner["examples"] as? [String]) ?? []
            cautions.append(examples.isEmpty
                ? "検査役のテストが通っていません: " + confirmed.joined(separator: "、")
                : "確かめてほしい点(どちらが正しいか見てください): " + examples.prefix(2).joined(separator: "/"))
        }
        // Rules the examiner wrote that the result breaks: weaker than an alarm (5 of 9 were real on 112 runs).
        if let examiner = result["examinerCheck"] as? [String: Any], let properties = examiner["properties"] as? [String],
           let first = properties.first {
            cautions.append("念のため確かめてください: 検査役が依頼から読んだ決まり「\(first)」に合わない結果がありました")
        }
        return cautions
    }
}
