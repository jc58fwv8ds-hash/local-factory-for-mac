import Foundation

/// 「動かない」 with no crash (2026-11-11, the user: 「ファクトリーに動かないよ。と送信したら直るようになるとよいね」).
/// 14Translate listened and showed nothing: the listener's partial text was published and never read, translation waited
/// for an `isFinal` that continuous speech hardly sends, and recognition errors stopped it without a word. These are found
/// in the code and go with the request, so the person only has to say that it does not work.
public enum NotWorkingHints {
    /// `request`: what the person said. A trap about how the app reads numbers aloud goes only with a report about reading
    /// (2026-11-13: 「全く何にも聞こえない」 came with the counter-reading task again, which had been set aside, and the model
    /// spent the run on it instead of on why nothing was heard).
    public static func hints(rootURL: URL, request: String = "") -> [String] {
        let files = TestFailureAnalyzer.swiftFiles(under: rootURL).filter { !$0.contains("Tests/") }
        let texts = files.compactMap { path in (try? String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8)).map { (path, $0) } }
        let traps = knownTraps(texts).filter { !$0.contains(readingHintMark) || aboutReading(request) }
        return unreadPublished(texts) + silentErrors(texts) + stopsOnReportedError(texts) + traps + untraced(texts)
    }

    static let readingHintMark = "日本語の読み上げは、数字と助数詞"

    /// Whether the person talks about how words or numbers are read (not about hearing nothing at all).
    static func aboutReading(_ request: String) -> Bool {
        ["読み間違", "読み方", "読みが", "発音", "助数詞", "数字", "数の", "にあたま"].contains { request.contains($0) }
    }

    /// What was found, for the person, in everyday words (2026-11-12, the user: the Factory should report like 「エラー4は翻訳
    /// モデルの処理失敗で、考えられる原因は…」, not a count of places in the code).
    public static func plain(_ hints: [String]) -> [String] {
        let words: [(String, String)] = [
            ("どこからも読まれていません", "聞き取った文字や訳などの中身が、画面に届いていない所があります。"),
            ("画面に出さずに捨てています", "うまくいかなかったときに、何が起きたかを画面に出さずに黙って捨てている所があります。"),
            ("ほとんど出力に書かれていません", "動いている途中の様子を記録に残していないため、iPhone で止まったときに原因がわかりません。節目ごとに記録を書くようにします。"),
            ("知らせたエラー", "聞き取りの部品が「声が入らない」などのやり直せる知らせを出すと、それを受けてアプリ全体が止まる作りになっていて、開始してもすぐ止まります。"),
            ("isFinal", "音声認識は音が途切れないと「文の終わり」を知らせないため、話が続くと訳が始まりません。"),
            ("区切りが来ず", "話し続ける音声では文の区切りが来ないため、音が止まるまで訳も読み上げも始まりません。一定の長さや文の終わりで先に区切る必要があります。"),
            ("約 1 分で打ち切られ", "音声認識は 1 回あたり約 1 分で打ち切られ、そのとき聞き取り全体を止めてしまっています。"),
            ("llama_decode", "翻訳モデルの処理が失敗することがあります。考えられる原因は、文が長すぎてモデルの入力の上限を超えたことと、前の処理が終わる前に次の処理が同じモデルを使ったことです。"),
            ("端末内の音声認識", "iPhone の中だけで聞き取るための音声データが入っていないと、聞き取りが動きません。"),
            ("フレームごとに認識を始め直して", "音の取り込みの途中で、ほんの一瞬(0.1 秒もない間隔)ごとに聞き取りを始め直しているため、一語も聞き取れず、何も聞こえない状態になっています。"),
            ("No speech detected」(1110)を", "iPhone の記録を見ると、聞き取りの部品は「声が入っていない」と何度も返していて、音が聞き取りまで届いていません。"),
            ("日本語の読み上げは、数字と助数詞", "読み上げは「2頭」のような数と助数詞の組み合わせを読み間違えます。人が言う読みに直してから読み上げる部品が要ります。"),
        ]
        var seen = Set<String>()
        return hints.compactMap { hint in words.first { hint.contains($0.0) }?.1 }.filter { seen.insert($0).inserted }
    }

    /// `@Published var name` holding what the person should see (text, a transcript, a translation) that no other file
    /// reads, with the type that holds the declaring type, where it should be passed on (2026-11-11: every unread value was
    /// named at first, and the model rebuilt the app's screen around eleven of them).
    static func unreadPublished(_ texts: [(String, String)]) -> [String] {
        let shown = ["text", "transcript", "translation", "partial", "result", "caption", "subtitle", "message"]
        return texts.flatMap { path, text -> [String] in
            guard let type = matches(#"(?:class|struct|actor)\s+(\w+)"#, in: text).first else { return [] }
            let names = matches(#"@Published\s+(?:private\(set\)\s+)?var\s+(\w+)"#, in: text)
                .filter { name in shown.contains { name.lowercased().contains($0) } }
            let holder = texts.first { other, body in other != path && body.range(of: #":\s*"# + type + #"\b"#, options: .regularExpression) != nil }
            return names.filter { name in
                !texts.contains { other, body in other != path && (body.contains("." + name) || body.contains("$" + name)) }
            }.map { name in
                let via = holder.map { "\($0.0) が \(type) を持っているので、そこで \(name) を受け取り、画面がすでに見ている値へ渡してください。" } ?? ""
                return "\(path) の \(type).\(name) は、人に見せる中身を作っていますが、どこからも読まれていません。" + via + "画面の作りは変えないでください。"
            }
        }
    }

    /// An error that is caught and dropped: nothing about it reaches the person.
    static func silentErrors(_ texts: [(String, String)]) -> [String] {
        texts.flatMap { path, text -> [String] in
            let lines = text.components(separatedBy: "\n")
            return lines.indices.compactMap { index -> String? in
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("if let error") || line.hasPrefix("if localError != nil") || line.hasPrefix("if error != nil")
                        || line == "} catch {" || line.hasSuffix("catch {") else { return nil }
                // The whole block, to its closing brace (2026-11-13: a catch that cleaned up for five lines and then rethrew
                // was reported as dropping its error, in every request of the day).
                var depth = 1, end = index + 1
                while end < min(lines.count, index + 16), depth > 0 {
                    depth += lines[end].filter { $0 == "{" }.count - lines[end].filter { $0 == "}" }.count
                    end += 1
                }
                let body = lines[(index + 1)..<end].joined(separator: " ")
                let tells = ["status", "Status", "message", "Message", "error.", "localizedDescription", "throw", "print(", "Logger", "alert"]
                guard !tells.contains(where: body.contains) else { return nil }
                return "\(path) の \(index + 1) 行目は、エラーを受け取っても、何が起きたかを画面に出さずに捨てています。状態の表示(statusText など)にエラーの内容を出してください。"
            }
        }
    }

    /// An error another part reports (a published `errorMessage`) that stops the whole run, when that part goes on by itself
    /// (2026-11-12: 14Translate's listener restarted after 「No speech detected」, and the controller watching its
    /// errorMessage stopped listening, translating and speaking: 「翻訳開始ボタンを押したが全く効果なし」).
    static func stopsOnReportedError(_ texts: [(String, String)]) -> [String] {
        texts.compactMap { path, text -> String? in
            guard let range = text.range(of: #"\$(errorMessage|error|lastError)\b[\s\S]{0,200}?\.sink"#, options: .regularExpression) else { return nil }
            let sink = text[range.upperBound...].prefix(900)
            guard sink.contains(".stop()") || sink.contains("isRunning = false"),
                  sink.range(of: "recoverable", options: .caseInsensitive) == nil else { return nil }  // already tells them apart
            return "\(path) は、別の部品が知らせたエラー(errorMessage など)を受け取ると、聞き取り・処理全体を止めています。"
                + "知らせてくる部品が自分でやり直せるエラー(音声認識の「No speech detected」や打ち切りなど)でも止まるので、開始してもすぐ止まります。"
                + "エラーは画面に出すだけにして、止めるのは利用者が止めたときと、続けられないエラー(許可がない、言語データがない)のときだけにしてください。"
        }
    }

    /// An app that writes almost nothing while it runs: when it stops on the iPhone, its output says nothing (2026-11-13).
    static func untraced(_ texts: [(String, String)]) -> [String] {
        let marks = texts.reduce(0) { count, file in
            count + ["print(", "Logger(", "logger.", "os_log(", "NSLog("].reduce(0) { $0 + file.1.components(separatedBy: $1).count - 1 }
        }
        guard texts.count >= 3, marks < texts.count else { return [] }
        return ["動いている途中の様子が、ほとんど出力に書かれていません(記録がないと、iPhone で止まったときに原因がわかりません)。"
            + "処理の節目(始めた・聞き取った文・訳し始めた・訳し終えた・読み上げを始めた・止めた・エラー)ごとに、print(\"[部品名] 何が起きたか\") を 1 行ずつ足してください。"]
    }

    /// Ways of using the system that are known not to work as they read.
    static func knownTraps(_ texts: [(String, String)]) -> [String] {
        var hints: [String] = []
        for (path, text) in texts {
            // Not when the code already ends a sentence after a pause (2026-11-12: the hint kept coming after it was fixed).
            if text.contains("recognitionTask(with:"), text.contains("isFinal"), !text.contains("Task.sleep"), !text.contains("Timer") {
                hints.append("\(path): 音声認識の isFinal は、音が途切れるか endAudio() を呼ぶまでほとんど来ません。流れ続ける音声では、部分結果(partial)が"
                    + "一定時間(1 秒ほど)変わらなかったら文の終わりとみなして渡し、認識を始め直してください。部分結果は画面にもそのまま出してください。")
            }
            // 2026-11-12: 14Translate spoke tens of seconds late, only after the video paused: a sentence ended only on silence.
            if text.contains("recognitionTask(with:"), text.contains("Task.sleep") || text.contains("Timer"),
               !["maxWords", "maxLength", "maxCharacters", "wordCount", "characterLimit"].contains(where: text.contains) {
                hints.append("\(path): 文の終わりを「部分結果が一定時間変わらないとき」だけで決めていると、話が途切れない音声(動画や講演)では区切りが来ず、"
                    + "音が止まるまで訳も読み上げも始まりません。部分結果が句点(. ? !)で終わる文を含んだらそこまでを先に渡し、"
                    + "それがなくても一定の長さ(英語なら 12〜15 語ほど、maxWords などの名前で)を超えたら、その時点で区切って渡してください。"
                    + "渡した分は覚えておき、次は残りだけを渡す(同じ文を二度訳さない)。")
            }
            // 2026-11-11: 14Translate stopped listening after a minute.
            // Not when the code already handles 1110 (2026-11-13: it kept coming after the fix).
            if text.contains("recognitionTask(with:"), text.contains("stop()"), !text.contains("1110") {
                hints.append("\(path): 1 回の音声認識は約 1 分で打ち切られ、エラーとして返ってきます。認識を始め直すときに古い認識を cancel() したときも、"
                    + "古い認識からエラーが返ります。これらのエラーで聞き取り全体を止めないでください。止めるのは利用者が止めたときだけにし、"
                    + "それ以外のエラーでは、新しい認識を始め直して聞き取りを続けてください(古い認識から返る結果とエラーは無視する)。"
                    + "「No speech detected」(kAFAssistantErrorDomain 1110)は、しばらく声が入らなかったときや、始め直した直後に普通に返るもので、"
                    + "エラーとして画面に出したり止めたりせず、黙って始め直してください。")
            }
            // 2026-11-12: 14Translate's translation failed with decodeFailed on the iPhone's own microphone (long run-on text).
            // Not when it already translates one at a time and keeps only the last sentences (2026-11-13: it kept coming).
            let handled = text.contains("actor ") && (text.contains("removeFirst()") || text.contains(".suffix("))
            if text.contains("llama_decode"), text.contains("n_ctx"), !handled {
                hints.append("\(path): 端末内のモデル(llama)は、入れ物(n_ctx)を超える長さを渡すと llama_decode が失敗します。長い入力は文や句読点で区切ってから 1 つずつ渡し、"
                    + "前の文脈(context)を足す分も含めて n_ctx に収まるよう長さを確かめてください。また同じモデルを 2 つの処理から同時に使うと失敗するので、"
                    + "翻訳は 1 つずつ順番に(actor や直列のキューで)行ってください。失敗しても聞き取りは止めず、その文だけ飛ばして続けてください。"
                    + "溜め込まないこと: 訳して読み上げ終えた文はすぐ捨て、前の文脈として渡すのは直近の 1〜2 文だけにしてください(2026-11-12、利用者の案)。")
            }
            // 2026-11-12: 14Translate read 「2頭」 as 「にあたま」; the first fix was a table of single words.
            if text.contains("AVSpeechSynthesisVoice(language: \"ja-JP\")") || text.contains("AVSpeechSynthesisVoice(language: \"ja\")") {
                hints.append("\(path): 日本語の読み上げは、数字と助数詞(2頭、3本、1匹、2人、8日、15分、3,500円 など)を読み間違えます。語を一つずつ置き換える表ではなく、"
                    + "Underdog-Woof-Japanese や Open JTalk と同じ考え方で、読み上げる前に「数(算用数字・漢数字・桁区切り)+助数詞」を見つけて、人が言う読み(ひらがな)に"
                    + "書き換える部品を作ってください。数の読み(いち、に、さん…、じゅう、ひゃく、せん、まん)と、助数詞ごとの音の変わり方(本: いっぽん/にほん/さんぼん/よんほん/ろっぽん/はっぽん/じゅっぽん、"
                    + "頭: いっとう/にとう/さんとう、匹: いっぴき/にひき/さんびき/ろっぴき/はっぴき/じゅっぴき、人: ひとり/ふたり/さんにん、日: ついたち/ふつか/みっか/よっか/いつか/むいか/なのか/ようか/ここのか/とおか/はつか、"
                    + "個: いっこ/にこ、回: いっかい、分: いっぷん/にふん/さんぷん/よんぷん/ごふん/ろっぷん/じゅっぷん、歳: いっさい/はたち、円・年・月・時・階・台・枚・冊・杯・件・点・度・番 など)を"
                    + "表で持ち、それ以外の文はそのまま渡す。この部品にはテストを付けてください(2頭→にとう、3本→さんぼん、20歳→はたち、3,500円→さんぜんごひゃくえん)。")
            }
            // 2026-11-13: 14Translate heard nothing at all: a "memory" fix restarted recognition every 2000 audio frames
            // (about 0.04 s at 48 kHz), so the recognizer never got a word and kept answering No speech detected (1110).
            if text.contains("installTap"), let limit = smallFrameRestart(text) {
                hints.append("\(path): 音声の取り込み(installTap)の中で、\(limit) フレームごとに認識を始め直しています。"
                    + "\(limit) フレームは 48kHz で約 \(String(format: "%.2f", Double(limit) / 48_000)) 秒しかなく、短すぎて認識が一語も聞き取れず、"
                    + "No speech detected(1110)が続いて何も聞こえなくなります。フレーム数で始め直す処理は外してください。"
                    + "始め直すのは、1 分の打ち切りのときと、文を区切って渡したときだけにしてください。")
            }
            if text.contains("requiresOnDeviceRecognition = true") {
                hints.append("\(path): 端末内の音声認識は、その言語の音声データが iPhone に入っていないと動きません。supportsOnDeviceRecognition が false のときや"
                    + "認識がエラーになったときは、理由を画面に出してください。")
            }
        }
        return hints
    }

    /// A restart counted in audio frames that is under five seconds at 48 kHz: the number behind a name such as
    /// `maxBufferedFramesThreshold`, when the file restarts recognition when it is passed.
    static func smallFrameRestart(_ text: String) -> Int? {
        guard text.range(of: #"restart\w*\(\)"#, options: .regularExpression) != nil else { return nil }
        let values = matches(#"\w*[Ff]rame\w*\s*(?::\s*Int)?\s*=\s*([0-9_]+)"#, in: text)
            .compactMap { Int($0.replacingOccurrences(of: "_", with: "")) }.filter { $0 > 0 && $0 < 240_000 }
        return values.min()
    }

    /// What the app's own output on the iPhone shows (2026-11-13: 「全く何にも聞こえない」 came with a record of nothing but
    /// No speech detected, again and again: the sound never reached the recognizer).
    public static func fromConsole(_ lines: [String]) -> [String] {
        let noSpeech = lines.filter { $0.contains("1110") || $0.localizedCaseInsensitiveContains("no speech detected") }.count
        guard noSpeech >= 3 else { return [] }
        return ["iPhone の記録では、音声認識が「No speech detected」(1110)を \(noSpeech) 回続けて返しています。音が認識に届いていません。"
            + "認識を短い間隔で始め直していないか、取り込んだ音(installTap の buffer)を今の認識の request に append しているか、"
            + "音声セッション(playAndRecord)を有効にしてから audioEngine を始めているかを確かめてください。"]
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
