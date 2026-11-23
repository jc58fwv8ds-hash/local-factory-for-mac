import Foundation

/// Whether a file's change does what its step of the plan asked, before it is saved (2026-11-16: the step said 「途中結果のた
/// びに翻訳と読み上げが実行されているのを、確定した部分か区切りごとに 1 回だけにする」; the writer added only a check against the
/// very same sentence twice, the build and tests passed, and the run said 「できました」 with the real fault untouched).
public enum StepCheck {
    public static let maximumDiffCharacters = 9_000

    public static let maximumFileCharacters = 16_000

    /// The first answer and two rewrites are checked; the third that still misses the step stops the run.
    public static let maximumChecks = 3

    /// `file` is the whole file after the change (2026-11-17: shown only the diff, the check said the fallback listener was
    /// missing because it was already in the file from the step before, unchanged; the step was rewritten, came back the
    /// same, and the run stopped with 「一部を入れられませんでした」 for something that was there).
    public static func request(step: String, path: String, diff: String, file: String? = nil) -> String {
        let whole = file.map { shown(file: $0, step: step, diff: diff) } ?? ""
        return """
        あるファイルへの変更が、計画のこの段階で頼まれたことを実際にしているかを確かめてください。

        頼まれたこと(\(path)):
        \(String(step.prefix(2_000)))

        変更(- は消した行、+ は足した行):
        \(String(diff.prefix(maximumDiffCharacters)))\(whole)

        頼まれたことのうち、このファイルですべきことを、変更後のファイルが実際にしていれば(前からあって今回変えていない部分でも)、1 行目に OK とだけ書いてください。
        していないこと(名前を変えただけ、似た別のことをしただけ、コメントだけ、一部だけ)があれば、
        1 行目に MISSING: と書き、そのあとに、していないことを日本語で 1〜3 文で具体的に書いてください。
        ほかのファイルですべきこと(このファイルに無いもの)は、MISSING に含めないでください。
        """
    }

    /// The whole file when it fits; a longer one as the functions the step or the change names (2026-11-18: 14Translate's
    /// TranslationController is 39,000 characters, the first 16,000 were shown, and the check said handleTranscript, the
    /// function the step was about, did not exist, three times over).
    static func shown(file: String, step: String, diff: String) -> String {
        if file.count <= maximumFileCharacters { return "\n\n変更後のファイル全文(変更していない部分も含む):\n" + file }
        let named = NotWorkingHints.functionBodies(file).filter { name, _ in
            step.contains(name) || diff.contains("func " + name) || diff.contains(name + "(")
        }
        var text = "", kept: [String] = []
        for (name, body) in named {
            let block = body.joined(separator: "\n")
            guard text.count + block.count <= maximumFileCharacters else { continue }
            text += block + "\n\n"
            kept.append(name)
        }
        guard !kept.isEmpty else { return "\n\n変更後のファイル(長いので先頭だけ):\n" + String(file.prefix(maximumFileCharacters)) }
        return "\n\n変更後のファイルは長いので、頼まれたことと変更に関わる関数(\(kept.joined(separator: "、")))の全文だけを載せます。"
            + "ここに無い部分も、ファイルには変更せずに残っています:\n" + text
    }

    /// What is still missing, or nil when the answer says OK or cannot be read.
    public static func missing(from answer: String) -> String? {
        let text = StructuredModelResponse.jsonText(from: answer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: "MISSING:") else { return nil }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.count >= 4 ? String(rest.prefix(600)) : nil
    }

    /// The changed lines only, for the check; lines that only moved or changed their indentation are left out
    /// (2026-11-18: a re-indented function filled the 9,000 characters the check is shown, and the real change was past them).
    public static func diffText(_ lines: [FileDiffLine]) -> String {
        func key(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }
        var removed: [String: Int] = [:], added: [String: Int] = [:]
        for line in lines {
            if line.kind == .removal { removed[key(line.text), default: 0] += 1 }
            if line.kind == .addition { added[key(line.text), default: 0] += 1 }
        }
        return lines.compactMap { line -> String? in
            let k = key(line.text)
            switch line.kind {
            case .addition: return removed[k, default: 0] > 0 ? nil : "+ " + line.text
            case .removal: return added[k, default: 0] > 0 ? nil : "- " + line.text
            default: return nil
            }
        }.joined(separator: "\n")
    }

    public static let feedbackMark = "前回の案は、この段階で頼まれたことの一部をしていませんでした: "

    public static func feedback(_ missing: String) -> String {
        "\n" + feedbackMark + missing + "\nそれも実際に行う形で、ファイルの全文を書き直してください。"
    }

    /// What the check said was missing, from an instruction it was added to.
    public static func missingNoted(in instruction: String) -> String? {
        guard let range = instruction.range(of: feedbackMark, options: .backwards) else { return nil }
        return instruction[range.upperBound...].components(separatedBy: "\n").first
    }
}
