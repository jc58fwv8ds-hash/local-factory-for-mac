import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

struct ScheduledInstructionTests {
    @Test(arguments: [
        ("毎朝8時にこのフォルダの写真を日付の名前にして", nil, 8, 0, "このフォルダの写真を日付の名前にして"),
        ("毎日 21:30 に売上表の合計を出して", nil, 21, 30, "売上表の合計を出して"),
        ("毎週月曜の9時に、先週の集計をして", 2, 9, 0, "先週の集計をして"),
        ("毎晩10時半にダウンロードを整理して", nil, 22, 30, "ダウンロードを整理して"),
        ("請求書を月ごとのフォルダ名にして。毎週金曜日 午後5時15分", 6, 17, 15, "請求書を月ごとのフォルダ名にして"),
    ] as [(String, Int?, Int, Int, String)])
    func fixedPhrasesAreBooked(text: String, weekday: Int?, hour: Int, minute: Int, rest: String) throws {
        let (schedule, instruction) = try #require(SchedulePhrase.parse(text))
        #expect(schedule == .init(weekday: weekday, hour: hour, minute: minute))
        #expect(instruction == rest)
    }

    @Test(arguments: ["8時に起こして", "毎朝の挨拶を考えて", "毎日 25時に集計して", "毎朝8時に", "今日は毎日が楽しい"])
    func ordinaryMessagesAreNotBooked(text: String) {
        #expect(SchedulePhrase.parse(text) == nil)
    }

    @Test func aMissedTimeRunsOnceAndThenWaitsForTheNextDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        var booking = ScheduledInstruction(instruction: "整理して", schedule: .init(hour: 8), created: at(11, 15))
        #expect(!booking.isDue(now: at(12, 7, 59), calendar: calendar))
        #expect(booking.isDue(now: at(12, 8), calendar: calendar))
        #expect(booking.isDue(now: at(14, 12), calendar: calendar))     // closed for two days: due
        booking.lastRun = at(14, 12)                                      // …and runs once
        #expect(!booking.isDue(now: at(15, 7), calendar: calendar))
        #expect(booking.isDue(now: at(15, 8), calendar: calendar))
        #expect(ScheduledInstruction.Schedule(weekday: 2, hour: 9, minute: 5).description == "毎週月曜 9:05")
    }

    @Test func olderProjectsWithoutBookingsStillLoad() throws {
        let data = try JSONEncoder().encode(HarnessProject.starter)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "scheduledInstructions")
        let project = try JSONDecoder().decode(HarnessProject.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(project.scheduledInstructions == nil)
    }
}

/// The chat flow: 「毎朝8時に…」 with a folder books the request instead of running it; when it is due, the same request
/// runs with the same folder and comes back as the usual rename card, and nothing is renamed until 適用する.
@MainActor
struct ScheduledInstructionChatTests {
    @Test func aBookedRenameRunsWhenDueAndStillWaitsForApply() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-chat-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("写真")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["IMG_0001.JPG", "IMG_0002.JPG"] { try Data().write(to: folder.appendingPathComponent(name)) }
        let repository = WorkspaceRepository(fileURL: base.appendingPathComponent("workspace.json"))
        var project = HarnessProject.starter
        project.selectedModel = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project)]))
        let store = WorkspaceStore(repository: repository, inferenceProvider: BulkRenameChatTests.RuleModel(
            reply: #"{"extensions": ["jpg"], "order": "name", "template": "旅行_{n:2}", "startNumber": 1}"#))
        store.attachFolder(folder)
        store.instruction = "毎朝8時にこのフォルダの写真を旅行_01 のような連番にして"
        store.submitInstruction()

        let booking = try #require(store.scheduledInstructions.first)
        #expect(booking.instruction == "このフォルダの写真を旅行_01 のような連番にして" && booking.folderPath == folder.path)
        #expect(store.renameChanges.isEmpty && store.instruction.isEmpty && store.attachedFolder == nil)

        store.runDueScheduledInstructions(now: booking.created)                             // not due at the moment of booking
        #expect(store.renameChanges.isEmpty)
        let due = try #require(booking.nextRun(after: booking.created))
        store.runDueScheduledInstructions(now: due)
        var change: RenameChange?
        for _ in 0..<200 {
            change = store.renameChanges.values.first { $0.status != .running }
            if change != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let ready = try #require(change)
        #expect(ready.status == .ready && ready.folder.path == folder.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["IMG_0001.JPG", "IMG_0002.JPG"])
        #expect(store.scheduledInstructions.first?.lastRun == due)
        #expect(store.renameChanges.count == 1)
        store.runDueScheduledInstructions(now: due.addingTimeInterval(60))            // already ran today
        #expect(store.renameChanges.count == 1)

        store.cancelScheduledInstruction(booking.id)
        #expect(store.scheduledInstructions.isEmpty)
    }
}
