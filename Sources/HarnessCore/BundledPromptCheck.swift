import Foundation

/// Marks of a bundled model's vocabulary written into the app's hand-built prompt that the model's own format does not
/// use, found after the build passes (2026-11-17: 14Translate put 「<s>」 in front of its PLaMo prompt; PLaMo begins with
/// 「<|plamo:bos|>」, which llama.cpp adds itself. Nothing failed and no person could have told; the model's file could).
public enum BundledPromptCheck {
    public static func diagnostics(rootURL: URL) -> [BuildFailureDiagnostic] {
        guard let model = BundledModelNotes.ggufFiles(under: rootURL).first,
              let template = BundledModelNotes.chatTemplate(of: model),
              let vocabulary = BundledModelNotes.vocabulary(of: model) else { return [] }
        let bos = vocabulary.bosID.flatMap { $0 < vocabulary.tokens.count ? vocabulary.tokens[$0] : nil }
        // Marks: vocabulary entries shaped like <…> with no spaces.
        let marks = Set(vocabulary.tokens.filter { $0.count >= 3 && $0.count <= 40 && $0.hasPrefix("<") && $0.hasSuffix(">") && !$0.contains(" ") })
        var allowed = Set(marks.filter { template.contains($0) })
        if let bos {
            if vocabulary.addBos { allowed.remove(bos) } else { allowed.insert(bos) }
        }
        let sources = TestFailureAnalyzer.swiftFiles(under: rootURL).filter { !$0.contains("Tests/") }
        var found: [BuildFailureDiagnostic] = []
        for path in sources {
            guard let text = try? String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8),
                  text.contains("<|") else { continue }   // only code that builds such prompts by hand
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                for literal in Self.literals(in: code) {
                    for mark in marks where !allowed.contains(mark) && literal.contains(mark) {
                        found.append(BuildFailureDiagnostic(validationKind: .build, relativePath: path, line: index + 1, column: nil,
                                                            message: message(mark: mark, bos: bos, added: vocabulary.addBos, model: model)))
                    }
                }
            }
        }
        return Array(found.prefix(4))
    }

    static func message(mark: String, bos: String?, added: Bool, model: URL) -> String {
        var text = "この行の文字列にある「\(mark)」は、同梱のモデル(\(model.lastPathComponent))の組み立て方にない印です。"
        if let bos {
            text += added ? "このモデルの始まりの印は「\(bos)」で、文字列を言葉に分けるときに自動で付きます。"
                : "このモデルの始まりの印は「\(bos)」です。"
        }
        return text + "モデルに渡す文字列から「\(mark)」を外し、モデルの組み立て方にある印だけを使ってください。"
    }

    /// The contents of the string literals on a line.
    static func literals(in line: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
            Range($0.range(at: 1), in: line).map { String(line[$0]) }
        }
    }
}
