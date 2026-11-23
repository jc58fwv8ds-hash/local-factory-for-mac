import Foundation

/// More ways a continuous app loses or repeats what it heard, found in 14Translate on 2026-11-18 after its tests passed:
/// a wait of `UInt64(0.8) * 1_000_000_000` nanoseconds is 0, so the silence check ran at once and never fired; the
/// in-progress text and the finished sentence were both sent to the same translation, so a sentence's first half was
/// translated twice; and recognition was torn down and started again after every sentence, so what was said meanwhile
/// was not heard.
extension NotWorkingHints {
    static let truncatedWaitMark = "小数を整数にしてから掛けた待ち時間"
    static let twoPathsMark = "途中の文と確定した文の両方"
    static let restartGapMark = "文ごとに聞き取りを止めて始め直す"

    public static func streamGaps(_ texts: [(String, String)]) -> [String] {
        var hints: [String] = []
        for (path, text) in texts {
            hints += truncatedWait(path: path, text: text)
            hints += twoPaths(path: path, text: text)
            hints += restartsPerSentence(path: path, text: text)
            hints += analyzerFormat(path: path, text: text)
            hints += converterInput(path: path, text: text)
        }
        return Array(hints.prefix(4))
    }

    /// `UInt64(seconds) * 1_000_000_000` where seconds may hold a fraction: the fraction is dropped before the multiply.
    static func truncatedWait(path: String, text: String) -> [String] {
        let pattern = #"UInt64\(([^()]*(\([^()]*\))?[^()]*)\)\s*\*\s*1_?000_?000_?000"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return [] }
        let found = String(text[range])
        return ["\(path): 「\(found)」は、秒を先に整数にしてから 10 億を掛けているため、0.8 秒のような小数は 0 秒になります(\(truncatedWaitMark))。"
            + "待ちがすぐ終わり、「しばらく間があいたら」の処理が働きません。UInt64(秒 * 1_000_000_000) のように、掛けてから整数にしてください。"]
    }

    /// One function reached both from a published in-progress value (`$partialText.sink`) and from the callback that
    /// delivers finished pieces.
    static func twoPathsTargets(_ text: String) -> (partial: Set<String>, final: Set<String>, direct: Set<String>) {
        let bodies = Dictionary(functionBodies(text).map { ($0.0, $0.1.joined(separator: "\n")) }, uniquingKeysWith: { a, _ in a })
        func calls(in snippet: String) -> Set<String> { Set(ProjectCallLookup.calledNames(snippet)) }
        func reach(_ names: Set<String>) -> Set<String> {
            names.union(names.flatMap { bodies[$0].map(calls(in:)) ?? [] })
        }
        var partial = Set<String>(), final = Set<String>(), direct = Set<String>()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            // The closure that starts here, up to the line that closes it (at most 8 lines).
            var end = index
            while end + 1 < min(lines.count, index + 8), !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("}") { end += 1 }
            let snippet = lines[index...end].joined(separator: "\n")
            let lower = line.lowercased()
            if line.contains("$"), lower.contains("partial") || lower.contains("volatile") || lower.contains("interim") {
                partial.formUnion(reach(calls(in: snippet)))
            } else if line.range(of: #"\.on[A-Z][A-Za-z]*(Final|Sentence|Transcript|Result)[A-Za-z]*\s*=\s*\{"#, options: .regularExpression) != nil {
                direct.formUnion(calls(in: snippet))
                final.formUnion(reach(calls(in: snippet)))
            }
        }
        return (partial, final, direct)
    }

    static func twoPaths(path: String, text: String) -> [String] {
        let (partial, final, direct) = twoPathsTargets(text)
        // The function the finished pieces are handed to, when the in-progress text reaches it too.
        let shared = partial.intersection(final).intersection(direct).filter { !["print", "append", "sink", "receive", "Task"].contains($0) }
        guard let name = shared.sorted().first else { return [] }
        // Where the in-progress side calls it, by function and line (2026-11-18: told only 「入口を 1 つに」, the writer three
        // times added a comparison inside the shared function and left the call from the in-progress side as it was).
        let lines = text.components(separatedBy: "\n")
        let caller = functionBodies(text).first { fn, body in
            partial.contains(fn) && fn != name && body.dropFirst().contains { ProjectCallLookup.calledNames($0).contains(name) }
        }
        var place = ""
        if let caller, let line = lines.indices.first(where: { index in
            lines[index].contains(name + "(") && !lines[index].contains("func ")
                && functionBodies(text).first(where: { $0.0 == caller.0 })?.1.contains(lines[index]) == true
        }) {
            place = "途中の文の側は \(caller.0) の中(\(line + 1) 行目「\(lines[line].trimmingCharacters(in: .whitespaces).prefix(60))」)で \(name) を呼んでいます。"
                + "この呼び出しと、そのための区切りの判定(語数・時間・文の終わり)を \(caller.0) から取り除き、\(caller.0) は画面の表示だけにしてください。"
                + "\(name) の中に比べる処理を足すのではなく、呼び出しそのものをやめること。間があいたときの区切りは、確定した文を出す側(聞き取り)に任せてください。"
        } else {
            place = "訳に回す入口は 1 つ(確定した文か、自分で区切った文のどちらか)にし、もう一方は画面に出すだけにしてください。"
        }
        return ["\(path): 聞き取りの\(twoPathsMark)(partial と確定した文)を、同じ \(name) に送っています。"
            + "途中の文を区切って訳したあと、確定した文にも同じ部分が入って届くので、同じ部分が 2 回訳され読み上げられます。" + place]
    }

    /// A SpeechAnalyzer listener that starts recognition again after each finished sentence.
    static func restartsPerSentence(path: String, text: String) -> [String] {
        guard text.contains("SpeechAnalyzer"), text.contains("SpeechTranscriber") else { return [] }
        for (name, body) in functionBodies(text) where name.lowercased().contains("final") || name.lowercased().contains("sentence") {
            // A restart only on some path (`if mode == .fallback { restart() }`) is not one after every sentence.
            let unconditional = body.enumerated().filter { index, line in
                index > 0 && !body[max(0, index - 2)..<index].contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("if ") }
            }.map(\.element).joined(separator: "\n")
            guard let restart = ProjectCallLookup.calledNames(unconditional).first(where: { $0.lowercased().hasPrefix("restart") }) else { continue }
            return ["\(path) の \(name) は、文を 1 つ受け取るたびに \(restart) で聞き取りを止めて始め直しています(\(restartGapMark))。"
                + "SpeechAnalyzer は話し続ける音声を区切りながら結果を出し続けるので、止める必要はありません。始め直すあいだに話された部分は聞き取られず、文が抜けます。"
                + "SpeechAnalyzer では文ごとに始め直さず、続けて結果を受け取ってください(始め直しは古い SFSpeechRecognizer で 1 回の上限に来たときだけにする)。"]
        }
        return []
    }

    static let analyzerFormatMark = "マイクの音をそのままの形式で"

    /// Microphone buffers given to SpeechAnalyzer as they come (2026-11-18: 14Translate stopped with SIGTRAP inside
    /// AnalyzerInput.init(buffer:) the moment it began to listen on the iPhone, every launch; the simulator tests use no
    /// microphone, so all passed). The analyzer takes only the format `bestAvailableAudioFormat(compatibleWith:)` gives.
    static func analyzerFormat(path: String, text: String) -> [String] {
        guard text.contains("AnalyzerInput(buffer:"), !text.contains("bestAvailableAudioFormat") || !text.contains("AVAudioConverter") else { return [] }
        return ["\(path): \(analyzerFormatMark) AnalyzerInput(buffer:) に渡しています。SpeechAnalyzer は決まった形式の音しか受け付けず、"
            + "形式が違うと AnalyzerInput.init(buffer:) の中でアプリが止まります(SIGTRAP。シミュレータのテストはマイクを使わないので通ります)。"
            + "聞き取りを始める前に let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) で形式を受け取り、"
            + "AVAudioConverter(from: マイクの形式, to: format) で、タップで受け取った音をその形式の AVAudioPCMBuffer に変換してから AnalyzerInput(buffer:) に渡してください。"]
    }

    static let converterInputMark = "変換に渡す音の受け渡し"

    /// An AVAudioConverter fed by a block that hands over the same buffer without saying it was the last, into an output
    /// sized from a fixed number (2026-11-18: 14Translate's converter returned the tap's buffer every time it was asked and
    /// sized the output from 1024 frames, while the tap gives several thousand; audio was repeated or cut).
    static func converterInput(path: String, text: String) -> [String] {
        guard let range = text.range(of: ".convert(to:") else { return [] }
        let after = String(text[range.lowerBound...].prefix(400))
        let setsStatus = after.contains("pointee")
        let fixedSize = text.range(of: #"AVAudioPCMBuffer\(pcmFormat:[^)]*frameCapacity:[^)]*\b1024\b"#, options: .regularExpression) != nil
            || text.range(of: #"frameCapacity\s*=\s*[^\n]*\b1024\b"#, options: .regularExpression) != nil
        guard !setsStatus || fixedSize else { return [] }
        var hint = "\(path): AVAudioConverter の\(converterInputMark)に問題があります。"
        if !setsStatus {
            hint += "convert(to:error:withInputFrom:) の入力の閉じかっこが、毎回同じ buffer を返し、outStatus を設定していません。"
                + "1 回目だけ outStatus.pointee = .haveData にして buffer を返し、2 回目からは outStatus.pointee = .noDataNow にして nil を返してください"
                + "(同じ音が何度も渡ったり、変換が終わらなかったりします)。"
        }
        if fixedSize {
            hint += "変換先の AVAudioPCMBuffer の大きさを 1024 などの決まった数から計算していますが、タップが渡す音はそれより長いことがあります(数千フレーム)。"
                + "AVAudioFrameCount(Double(buffer.frameLength) * 変換先の sampleRate / 元の sampleRate) + 1 のように、受け取った buffer.frameLength から計算してください(足りないと音が切れて言葉が抜けます)。"
        }
        return [hint]
    }
}
