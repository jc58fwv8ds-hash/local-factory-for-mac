import Foundation

/// Code that loses what the person said without an error (2026-11-18: 14Translate passed all 33 tests, yet a sentence that
/// came while the one before was being translated cancelled that translation and emptied the waiting list, and its
/// 「時間が経ったら訳す」 check set the time to now just before it measured how long it had been, so it never fired).
/// Neither shows in a test that sends one sentence; both make a continuous app drop sentences.
extension NotWorkingHints {
    static let droppedInputMark = "待っている入力を捨てて"
    static let zeroElapsedMark = "経った時間がいつも 0"

    public static func dropsInput(_ texts: [(String, String)]) -> [String] {
        var hints: [String] = []
        for (path, text) in texts {
            for (name, body) in functionBodies(text) {
                hints += discardsQueue(path: path, name: name, body: body)
                hints += measuresFromNow(path: path, name: name, body: body)
            }
        }
        return Array(hints.prefix(4))
    }

    /// `queue.removeAll()` in the same function that then appends the new item to that queue.
    static func discardsQueue(path: String, name: String, body: [String]) -> [String] {
        var hints: [String] = []
        for (index, line) in body.enumerated() {
            guard let range = line.range(of: #"([A-Za-z_][A-Za-z0-9_]*)\.removeAll\(\)"#, options: .regularExpression) else { continue }
            let queue = String(line[range].prefix { $0 != "." })
            guard body[(index + 1)...].contains(where: { $0.contains(queue + ".append(") }) else { continue }
            let cancels = body.contains { $0.contains(".cancel()") }
            hints.append("\(path) の \(name) は、新しい入力が来ると \(queue) を空にして(\(droppedInputMark))\(cancels ? "、途中の処理も取り消して" : "")から、新しい入力だけを入れています。"
                + "続けて入ってくる入力(話し続ける声など)では、前の入力が処理されないまま消えます。すべての入力を扱うべきなら、前の入力を捨てずに順番に処理してください。"
                + "遅れが心配なら、取り消しではなく、次の入力を待たずに並行して進めるか、短く区切って処理を速くしてください。")
            break
        }
        return hints
    }

    /// `last = Date()` followed, in the same function, by `Date().timeIntervalSince(last)` with no wait in between.
    static func measuresFromNow(path: String, name: String, body: [String]) -> [String] {
        for (index, line) in body.enumerated() {
            guard let range = line.range(of: #"([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*Date\(\)"#, options: .regularExpression) else { continue }
            // A new constant (`let start = Date()`) timed in a loop below is a timeout, not a reset of the last time.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") { continue }
            let variable = String(line[range].prefix { $0 != " " && $0 != "=" })
            for later in body[(index + 1)...] {
                let next = later.trimmingCharacters(in: .whitespaces)
                if next.hasPrefix("while ") || next.hasPrefix("for ") || next.hasPrefix("repeat") || next.hasPrefix("return") { break }
                if later.contains("await ") || later.contains(variable + " =") && !later.contains("==") { break }
                if later.contains("timeIntervalSince(" + variable + ")") || later.contains("timeIntervalSince(self." + variable + ")") {
                    return ["\(path) の \(name) は、\(variable) を今の時刻にした直後に、そこから経った時間を測っています(\(zeroElapsedMark))。"
                        + "この「一定時間たったら」の条件は決して満たされません。経った時間は、時刻を今に更新する前に測ってください。"]
                }
            }
        }
        return []
    }

    /// Each function's name and lines, by brace depth from its `func` line.
    static func functionBodies(_ text: String) -> [(String, [String])] {
        let lines = text.components(separatedBy: "\n")
        var result: [(String, [String])] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: #"func ([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) else { index += 1; continue }
            let name = String(trimmed[range].dropFirst(5))
            var depth = 0, started = false, body: [String] = []
            var end = index
            while end < lines.count {
                let line = lines[end]
                body.append(line)
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                if line.contains("{") { started = true }
                if started, depth <= 0 { break }
                end += 1
            }
            result.append((name, body))
            index = end + 1
        }
        return result
    }
}
