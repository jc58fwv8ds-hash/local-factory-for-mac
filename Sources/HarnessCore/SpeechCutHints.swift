import Foundation

/// Speech that a continuous app cuts or drops without an error (2026-11-19: 14Translate showed each translated piece as it
/// came and spoke it, but before each piece it stopped the speech in progress and emptied the speaker's queue, so a piece
/// was cut off by the next; the speaker also threw away the oldest waiting piece once three were waiting).
extension NotWorkingHints {
    static let cutsSpeechMark = "読み上げ中の声を止めてから"
    static let capsQueueMark = "待ちが決まった数を超えると古いものを捨て"

    public static func speechCuts(_ texts: [(String, String)]) -> [String] {
        let bodies = texts.map { ($0.0, functionBodies($0.1)) }
        // The project's own functions that stop speech at once (`stopNow` wrapping `stopSpeaking(at: .immediate)`).
        let stoppers = Set(bodies.flatMap { $0.1 }.filter { $0.1.dropFirst().contains { $0.contains("stopSpeaking(at:") } }.map(\.0))
        // The project's own speak functions that already add to a waiting list (`queue.append(…)`): then removing the stop is
        // the whole fix (2026-11-19: the writer removed it, the check looked for new queue code in the caller, found none, and
        // the step was rejected three times).
        let queueing = Set(bodies.flatMap { $0.1 }.filter { fn, body in
            fn.lowercased().hasPrefix("speak") && body.dropFirst().contains { $0.range(of: #"\b\w*(queue|Queue|pending|waiting)\w*\.append\("#, options: .regularExpression) != nil }
        }.map(\.0))
        var hints: [String] = []
        for (path, functions) in bodies {
            for (name, body) in functions {
                hints += cutsSpeech(path: path, name: name, body: body, stoppers: stoppers, queueing: queueing)
                hints += capsQueue(path: path, name: name, body: body)
            }
        }
        return Array(hints.prefix(3))
    }

    /// A function that stops the speech in progress and then starts speaking something new.
    static func cutsSpeech(path: String, name: String, body: [String], stoppers: Set<String>, queueing: Set<String> = []) -> [String] {
        let lower = name.lowercased()
        guard !stoppers.contains(name), !["stop", "cancel", "reset", "finish", "end", "pause"].contains(where: lower.hasPrefix) else { return [] }
        for (index, line) in body.enumerated().dropFirst() {
            let stops = line.contains("stopSpeaking(at:") || stoppers.contains { line.contains("." + $0 + "(") || line.contains(" " + $0 + "(") }
            guard stops else { continue }
            // Only what follows in the same block: a stop inside `if failed { …; return }` that closes before any speech is
            // a stop path, not a cut (2026-11-19: the translator-missing branch of 14Translate stopped speech and returned).
            var depth = 0, speak: String?
            for later in body[(index + 1)...] {
                if later.range(of: #"\.speak\w*\("#, options: .regularExpression) != nil
                    || later.range(of: #"\b(startSpeaking|speak)\("#, options: .regularExpression) != nil && !later.contains("func ") { speak = later; break }
                depth += later.filter { $0 == "{" }.count - later.filter { $0 == "}" }.count
                if depth < 0 { break }
            }
            guard let speak else { continue }
            let stop = line.trimmingCharacters(in: .whitespaces)
            let head = "\(path) の \(name) は、新しい文を話す前に、\(cutsSpeechMark)(\(stop.prefix(50)))、"
                + "続けて「\(speak.trimmingCharacters(in: .whitespaces).prefix(60))」で話しています。文が続けて届くと、前の文が言い終わる前に切れ、待っていた文も消えます。"
            if let queued = queueing.first(where: { speak.contains("." + $0 + "(") }) {
                return [head + "\(queued) は、もともと新しい文を待ち行列の後ろに足して順に話す作りです。\(name) の中の「\(stop.prefix(50))」の行を消すだけで、"
                    + "文は順に最後まで読まれます(待ち行列の処理を新しく書く必要はありません)。止めるのは、利用者が停止したときと画面を離れたときだけにすること。"]
            }
            return [head + "新しい文は止めずに読み上げの待ち行列の後ろに足して、順に言い終えるようにしてください。止めるのは、利用者が停止したときと画面を離れたときだけにすること。"]
        }
        return []
    }

    /// `if queue.count >= max { queue.removeFirst() }`: the oldest waiting item is thrown away when more come.
    static func capsQueue(path: String, name: String, body: [String]) -> [String] {
        for (index, line) in body.enumerated() {
            guard let range = line.range(of: #"([A-Za-z_][A-Za-z0-9_]*)\.count\s*>=?\s*[A-Za-z_0-9]+"#, options: .regularExpression) else { continue }
            let queue = String(line[range].prefix { $0 != "." })
            // A list kept for waiting work, not a history trimmed to its last entries.
            guard ["queue", "pending", "waiting", "buffer"].contains(where: queue.lowercased().contains), body[(index + 1)..<min(body.count, index + 4)].contains(where: { $0.contains(queue + ".removeFirst()") }) else { continue }
            return ["\(path) の \(name) は、\(queue) の\(capsQueueMark)ています。話し続ける人の声を訳して読むアプリでは、文が黙って抜けます。"
                + "捨てずにすべて順番に扱い、遅れが心配なら読み上げを少し速くするなど、抜かさない方法にしてください。"]
        }
        return []
    }
}
