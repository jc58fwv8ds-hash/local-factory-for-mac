import Foundation

/// The same failure written to the iPhone's log over and over, traced back to the code that writes it (2026-11-16, the user:
/// 「ファクトリー自律的にこの原因が分かる？」). 14Translate printed 「翻訳結果が不適切です」 and 「再翻訳も失敗。原文を返します」
/// for every sentence: its check that a translation was good asked for the English words inside the Japanese, so every
/// translation was thrown away. Nothing crashed and no known trap matched; only the repetition pointed at the check.
extension NotWorkingHints {
    static let failureWords = ["失敗", "不適切", "エラー", "できません", "できない", "原文を返", "error", "failed", "failure",
                               "invalid", "fallback", "could not", "cannot", "unable"]
    static let repeatedMark = "毎回同じ失敗"

    public static func repeatedFailures(_ console: [String], rootURL: URL, minimum: Int = 3) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in console {
            guard let message = failureMessage(line) else { continue }
            if counts[message] == nil { order.append(message) }
            counts[message, default: 0] += 1
        }
        let repeated = order.filter { counts[$0, default: 0] >= minimum }
        guard !repeated.isEmpty else { return [] }
        let files = TestFailureAnalyzer.swiftFiles(under: rootURL).filter { !$0.contains("Tests/") }
        let texts = files.compactMap { path in
            (try? String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8)).map { (path, $0) }
        }
        return repeated.prefix(2).compactMap { message in
            trace(message, count: counts[message] ?? 0, in: texts)
        }
    }

    /// The fixed part of a failure line: the words after a `[Tag]`, before a `: ` that starts the varying detail.
    static func failureMessage(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if let colon = text.range(of: ": ") { text = String(text[..<colon.lowerBound]) }
        let lower = text.lowercased()
        guard text.count >= 4, text.count <= 80, failureWords.contains(where: { lower.contains($0) }) else { return nil }
        return text
    }

    static func trace(_ message: String, count: Int, in texts: [(String, String)]) -> String? {
        let needle = String(message.prefix(24))
        for (path, text) in texts {
            let lines = text.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("\"") && $0.contains(needle) }) else { continue }
            let place = BuildRepairTarget.enclosing(line: index + 1, in: lines) ?? "ファイルの中"
            let condition = (max(0, index - 15)..<index).reversed().map { lines[$0].trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("if ") || $0.hasPrefix("guard ") || $0.hasPrefix("} else if ") || $0.hasPrefix("while ") }
            var hint = "iPhone の記録で「\(message)」が \(count) 回、\(repeatedMark)が出ています。これは \(path) の \(place)(\(index + 1) 行目)で書かれています。"
            if let condition {
                hint += "そこに至る条件は「\(condition.prefix(160))」です。"
            }
            hint += "どの入力でも同じ失敗になるなら、入力ではなく、失敗と決めている判定や処理そのものが間違っている可能性が高いです。"
                + "正しい結果までその判定ではじいていないか、判定の中身を確かめて直してください。"
            if let condition, let body = calledFunctionBody(condition, in: texts) {
                hint += "\n判定に使っている関数:\n" + body
            }
            return hint
        }
        return nil
    }

    /// The first lines of a project function the condition calls (`isInvalidTranslation(…)`).
    static func calledFunctionBody(_ condition: String, in texts: [(String, String)]) -> String? {
        let names = ProjectCallLookup.calledNames(condition)
        for name in names {
            for (path, text) in texts {
                let lines = text.components(separatedBy: "\n")
                guard let start = lines.firstIndex(where: { ProjectCallLookup.declaredName($0.trimmingCharacters(in: .whitespaces)) == name }) else { continue }
                let body = lines[start..<min(lines.count, start + 30)].joined(separator: "\n")
                return "--- \(path) ---\n" + body
            }
        }
        return nil
    }

    /// Speech recognition set up for one short query while the app listens to a conversation (2026-11-16: 14Translate's
    /// listener used `.search`, took 「Mandarin」 as a whole query and ended there; a final result that did not end with
    /// 「.」 started no new task, so 30 seconds of TV gave two words).
    static let shortQueryMark = "検索語向け(.search)"

    public static func listensForOneQuery(_ texts: [(String, String)]) -> [String] {
        texts.compactMap { path, text in
            guard text.contains("SFSpeechAudioBufferRecognitionRequest"), text.contains("taskHint = .search") else { return nil }
            return "\(path): 音声認識の taskHint が \(shortQueryMark) になっています。これは短い語句を 1 つ聞いて終える設定で、"
                + "会話を聞き続けると最初の語句(例: 「Mandarin」)で結果が確定し、そこで認識が終わります。taskHint = .dictation にしてください。"
                + "また、結果が確定したら、文の終わりの記号があってもなくても、必ず次の認識を始め直してください。"
                + "始め直さないと、そのあとは何も聞き取りません。"
        }
    }

    /// A sentence heard bit by bit, each longer piece handled again from the start (2026-11-16: 14Translate translated
    /// 「They don't give anything」, 「… to」, 「… to people like」, 「… to people like me」 one after another, twice each, and read each
    /// aloud, so it fell behind, cancelled its own work and translated only now and then).
    static let growingMark = "だんだん長くなる同じ文"

    public static func growingPieces(_ console: [String], minimum: Int = 3) -> [String] {
        var chains = 0
        var longest: [String] = []
        var current: [String: [String]] = [:]
        func close(_ chain: [String]) {
            guard chain.count >= minimum else { return }
            chains += 1
            if chain.count > longest.count { longest = chain }
        }
        for line in console {
            guard let colon = line.range(of: ": ") else { continue }
            let tag = String(line[..<colon.lowerBound])
            let text = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard text.count >= 2, !tag.isEmpty, !text.hasSuffix("...") else { continue }
            if current[tag]?.last == text { continue }
            if let last = current[tag]?.last, text.count > last.count, text.hasPrefix(last) {
                current[tag, default: []].append(text)
            } else {
                close(current[tag] ?? [])
                current[tag] = [text]
            }
        }
        current.values.forEach(close)
        guard chains > 0 else { return [] }
        return ["iPhone の記録では、聞き取りの途中結果(\(growingMark): 「\(longest.first ?? "")」→ … →「\(longest.last ?? "")」)を、"
            + "長くなるたびに頭から訳し直して(読み上げて)います。これでは訳が追いつかず、遅れて取り消しが重なり、ときどきしか訳されません。"
            + "途中結果は画面に出すだけにし、訳と読み上げは、確定した部分か区切り(文の終わり・少しの間・一定の語数)ごとに 1 回だけ行ってください。"
            + "読むのはまだ読んでいない新しい部分だけにし、同じ文を 2 回訳さないでください。読み上げの終わりを待たずに次の聞き取りと訳を進めてください。"]
    }

    /// A long piece cut into parts and worked through part by part, with nothing shown until all are done (2026-11-19: 14Translate
    /// heard 「For the FBI. Yeah, take it. I mean, …」 as one piece, translated it in 9 parts one after another, and the
    /// person pressed stop before the first words came out: 「何にも始まらず」).
    static let batchedMark = "全部の区切りを訳し終えるまで何も出さない"

    public static func batchedPieces(_ console: [String], minimum: Int = 4) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(\d+)\s*/\s*(\d+)"#)
        var largest = 0
        var stoppedMidway = false
        var current = 0, total = 0
        for line in console {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let a = Range(match.range(at: 1), in: line), let b = Range(match.range(at: 2), in: line),
               let index = Int(line[a]), let count = Int(line[b]), count >= minimum, count <= 200, index <= count {
                current = index; total = count
                largest = max(largest, count)
            } else if total > 0, current < total, line.lowercased().contains("stop") {
                stoppedMidway = true
            }
        }
        guard largest >= minimum else { return [] }
        return ["iPhone の記録では、聞き取った長いまとまりを \(largest) 個に区切り、1 つずつ順に処理していて(\(batchedMark))、"
            + (stoppedMidway ? "途中で止められています。" : "最初の結果が出るまでに時間がかかっています。")
            + "区切りを全部終えてから結果を返すのではなく、1 つ終わるたびにすぐ画面に出し、読み上げを始めてください。"
            + "聞き取った文は、文の終わりや短い間ごとに分けて、長いまとまりにためずに次へ渡してください。"]
    }
}
