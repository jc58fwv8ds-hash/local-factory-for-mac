import Foundation

/// A continuous translator that is slow and shows one line at a time (2026-11-22, the user, after trying 14Translate:
/// 「字幕は表示欄を大きく取ってるのに、一部にこんな感じで出て次が来るとすぐ消える」「遅い」). Its translator cut each sentence
/// at every comma and sent the pieces to the model one by one, and the screen showed only the newest translation although
/// a list of them was kept.
extension NotWorkingHints {
    static let commaSplitMark = "読点やカンマでも文を切って"
    static let latestOnlyMark = "最新の 1 件だけを出して"

    public static func subtitleGaps(_ texts: [(String, String)]) -> [String] {
        var hints: [String] = []
        for (path, text) in texts {
            hints += commaSplit(path: path, text: text)
            hints += latestOnly(path: path, text: text, all: texts)
            hints += newestOnTop(path: path, text: text, all: texts)
        }
        return Array(hints.prefix(3))
    }

    /// A list of separator characters that holds both a sentence end and a comma, in a file that calls a model per piece.
    static func commaSplit(path: String, text: String) -> [String] {
        let translates = ["translate", "Translat", "generate", "completion", "infer"].contains(where: text.contains)
        guard translates else { return [] }
        for (name, body) in functionBodies(text) where name.lowercased().contains("split") || name.lowercased().contains("segment") {
            let joined = body.joined(separator: "\n")
            let sentenceEnd = ["\"。\"", "\".\"", "\"?\"", "\"？\""].contains(where: joined.contains)
            let comma = ["\"、\"", "\",\"", "\"，\""].contains(where: joined.contains)
            guard sentenceEnd, comma else { continue }
            return ["\(path) の \(name) は、文の終わりだけでなく、\(commaSplitMark)います。切った部分ごとに翻訳モデルを呼ぶので、"
                + "1 文に何回も待ちが入って遅くなり、「食事なし、」「仕事なし、」のように意味の切れた訳になります。"
                + "区切りは文の終わり(。.?!？!)だけにして、1 文をまとめて 1 回で訳してください。長すぎる文だけ、語数で切ること。"]
        }
        return []
    }

    /// A screen whose main text is one `lastX` value of an object that also keeps a list of past results the screen does
    /// not list.
    static func latestOnly(path: String, text: String, all: [(String, String)]) -> [String] {
        guard text.contains("View"), !text.contains("ForEach"),
              let range = text.range(of: #"Text\(\s*\w+\.(last|latest|current)[A-Z]\w*\)"#, options: .regularExpression) else { return [] }
        let shown = String(text[range])
        let keepsList = all.contains { $0.1.range(of: #"(history|items|lines|subtitles|results)\s*(:|=)\s*\["#, options: .regularExpression) != nil
            || $0.1.contains(".insert(") && $0.1.contains("history") }
        guard keepsList else { return [] }
        return ["\(path) は、字幕の場所に「\(shown)」で\(latestOnlyMark)います。次の結果が来ると前の字幕はすぐ消え、読み切れません。"
            + "話し続ける人の通訳では、字幕の場所いっぱいに、これまでの結果を古い順に並べ(ScrollView と ForEach)、新しい字幕を下に足して、"
            + "自動で一番下までスクロールしてください。古いものは上へ流れて見えなくなるだけで、消さないこと。"]
    }

    static let newestOnTopMark = "新しい字幕を先頭に入れて"

    /// A subtitle list scrolled to its last item while the results are inserted at the front (2026-11-23: 14Translate
    /// kept the newest translation at index 0, listed it at the top and scrolled to the bottom, to the oldest; and showed
    /// 「待機中」 until a second translation came, hiding the first).
    static func newestOnTop(path: String, text: String, all: [(String, String)]) -> [String] {
        guard text.contains("ForEach"), text.contains("scrollTo("),
              let last = text.range(of: #"(\w+)\.last\b"#, options: .regularExpression) else { return [] }
        let list = String(text[last].dropLast(5))
        var hints: [String] = []
        if let other = all.first(where: { $0.1.range(of: #"\b\#(list)\.insert\([^)]*at:\s*0\)"#, options: .regularExpression) != nil }) {
            hints.append("\(other.0) は\(newestOnTopMark)いる(\(list).insert(…, at: 0))のに、\(path) は一覧の最後(一番古いもの)へスクロールしています。"
                + "新しい字幕が一番上に出て、画面は古いほうへ送られます。\(list) には append で古い順に足し、多すぎるときは removeFirst で古いほうを捨て、"
                + "画面は ForEach で古い順に並べて、最後(一番新しいもの)へスクロールしてください。件数が上限で変わらなくても送られるよう、"
                + "スクロールのきっかけは件数ではなく最後の id の変化(.onChange(of: \(list).last?.id))にすること。")
        }
        if text.range(of: #"\.count\s*>\s*1\b"#, options: .regularExpression) != nil {
            hints.append("\(path) は、字幕が 2 件以上になるまで一覧を出していません(count > 1)。最初の 1 件目の訳が見えないので、1 件でもあれば出してください。")
        }
        return hints
    }
}
