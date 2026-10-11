import Foundation

/// A chat instruction the user booked to run again at a fixed time (backlog #43, 2026-10-11, after DeepSeek Harness's
/// scheduled jobs): "毎朝8時にこのフォルダの写真を日付の名前にして". At the time, the app sends the instruction with the
/// same attachments as if it were typed. The result comes back as the usual card; nothing is applied until the user
/// presses 適用する, so a booked run can never change files on its own.
public struct ScheduledInstruction: Identifiable, Codable, Equatable, Sendable {
    public struct Schedule: Codable, Equatable, Sendable {
        /// 1 = Sunday … 7 = Saturday (Calendar's numbering); nil = every day.
        public var weekday: Int?
        public var hour: Int
        public var minute: Int

        public init(weekday: Int? = nil, hour: Int, minute: Int = 0) {
            self.weekday = weekday; self.hour = hour; self.minute = minute
        }

        public var description: String {
            let time = String(format: "%d:%02d", hour, minute)
            guard let weekday else { return "毎日 \(time)" }
            return "毎週\(["日", "月", "火", "水", "木", "金", "土"][(weekday - 1) % 7])曜 \(time)"
        }
    }

    public let id: UUID
    public var instruction: String
    public var schedule: Schedule
    public var documentPaths: [String]
    public var folderPath: String?
    public var created: Date
    public var lastRun: Date?

    public init(id: UUID = UUID(), instruction: String, schedule: Schedule, documentPaths: [String] = [],
                folderPath: String? = nil, created: Date = Date(), lastRun: Date? = nil) {
        self.id = id; self.instruction = instruction; self.schedule = schedule
        self.documentPaths = documentPaths; self.folderPath = folderPath; self.created = created; self.lastRun = lastRun
    }

    /// The first scheduled time after `date`.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents(hour: schedule.hour, minute: schedule.minute)
        components.weekday = schedule.weekday
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }

    /// Due when a scheduled time has passed since the last run (or since it was booked). A time missed while the app was
    /// closed runs once when it opens again, not once per missed day.
    public func isDue(now: Date, calendar: Calendar = .current) -> Bool {
        guard let next = nextRun(after: lastRun ?? created, calendar: calendar) else { return false }
        return next <= now
    }
}

/// Reads a booking at the start or end of a message: 「毎朝8時に…」「毎日 21:30 に…」「毎週月曜の9時に…」「…を毎晩10時に」.
/// Only these fixed phrasings count, so an ordinary message is never booked by accident.
public enum SchedulePhrase {
    public static func parse(_ text: String) -> (ScheduledInstruction.Schedule, String)? {
        let pattern = #"(毎朝|毎晩|毎夜|毎日|毎週\s*([日月火水木金土])曜(?:日)?)\s*(?:の\s*)?(午前|午後)?\s*(\d{1,2})\s*(?:時\s*(?:(\d{1,2})\s*分|半)?|[:：]\s*(\d{2}))\s*(?:に|から)?\s*[、,]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text) else { return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        guard var hour = group(4).flatMap(Int.init) else { return nil }
        var minute = group(5).flatMap(Int.init) ?? group(6).flatMap(Int.init) ?? 0
        if group(5) == nil, group(6) == nil, text[whole].contains("半") { minute = 30 }
        let word = group(1) ?? ""
        if group(3) == "午後" || ((word == "毎晩" || word == "毎夜") && hour < 12) { if hour < 12 { hour += 12 } }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let weekday = group(2).flatMap { ["日", "月", "火", "水", "木", "金", "土"].firstIndex(of: $0) }.map { $0 + 1 }
        var rest = text
        rest.removeSubrange(whole)
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "、,。")))
        guard !rest.isEmpty else { return nil }
        return (.init(weekday: weekday, hour: hour, minute: minute), rest)
    }
}
