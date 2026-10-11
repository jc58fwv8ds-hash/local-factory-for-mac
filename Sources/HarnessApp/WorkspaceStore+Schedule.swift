import Foundation
import HarnessCore

/// Booked instructions (backlog #43, 2026-10-11). 「毎朝8時に…」 with files or a folder attached books the instruction
/// instead of running it; the app checks every minute and sends a due one as if it were typed, so it comes back as the
/// usual card and waits for 適用する. A booked run only starts while the composer is empty and nothing else is running.
extension WorkspaceStore {
    var scheduledInstructions: [ScheduledInstruction] { project.scheduledInstructions ?? [] }

    /// Books the message when it starts or ends with a fixed schedule phrase; returns false for any other message.
    func submitScheduleBooking(_ text: String) -> Bool {
        guard let (schedule, rest) = SchedulePhrase.parse(text) else { return false }
        let booking = ScheduledInstruction(instruction: rest, schedule: schedule,
                                           documentPaths: documentAttachments.compactMap(\.sourcePath),
                                           folderPath: attachedFolder?.path)
        library.updateSelectedProject {
            $0.conversation.append(ConversationMessage(role: .user, content: text, origin: .user))
            $0.scheduledInstructions = ($0.scheduledInstructions ?? []) + [booking]
        }
        let attached = booking.documentPaths.map { URL(fileURLWithPath: $0).lastPathComponent } + [booking.folderPath.map { "フォルダ「\(URL(fileURLWithPath: $0).lastPathComponent)」" }].compactMap { $0 }
        appendAssistantNote("予約しました: \(schedule.description) に「\(rest)」\(attached.isEmpty ? "" : "(\(attached.joined(separator: "、")))")。"
            + "時間になったら案をカードで出します。ファイルが変わるのは「適用する」を押したときだけです。このプロジェクトを開いているあいだに実行し、閉じていた時間の分は次に開いたときに 1 回だけ実行します。")
        return true
    }

    func cancelScheduledInstruction(_ id: UUID) {
        guard let booking = scheduledInstructions.first(where: { $0.id == id }) else { return }
        library.updateSelectedProject { $0.scheduledInstructions?.removeAll { $0.id == id } }
        appendAssistantNote("予約を取り消しました: \(booking.schedule.description)「\(booking.instruction)」")
    }

    /// Sends the first due booking, if the composer is free. Called every minute by the app.
    func runDueScheduledInstructions(now: Date = Date()) {
        guard instruction.isEmpty, documentAttachments.isEmpty, interactionBlocker(for: .submitInstruction) == nil,
              let booking = scheduledInstructions.first(where: { $0.isDue(now: now) }) else { return }
        library.updateSelectedProject { project in
            guard let index = project.scheduledInstructions?.firstIndex(where: { $0.id == booking.id }) else { return }
            project.scheduledInstructions?[index].lastRun = now
        }
        persist()
        let missing = (booking.documentPaths + [booking.folderPath].compactMap { $0 }).filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else {
            appendAssistantNote("予約(\(booking.schedule.description)「\(booking.instruction)」)を実行できませんでした。見つからないもの: "
                + missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、"))
            return
        }
        let previousFolder = attachedFolder
        attachedFolder = booking.folderPath.map { URL(fileURLWithPath: $0) }
        attachDocuments(booking.documentPaths.map { URL(fileURLWithPath: $0) })
        instruction = booking.instruction
        appendAssistantNote("予約の時間です(\(booking.schedule.description))。「\(booking.instruction)」を実行します。")
        submitInstruction()
        attachedFolder = previousFolder
    }
}
