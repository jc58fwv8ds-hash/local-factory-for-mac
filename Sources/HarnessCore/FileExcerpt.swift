import Foundation

/// A long file shown as its outline and the parts the request is about, not whole (2026-11-25, the user: 「大きなファイルの
/// 目次化」). Reading the prompt is what takes the time now that answers hold only the changed lines (ReplaceEdit): about
/// 370 tokens a second on this Mac, so 14Translate's 37,000-character TranslationController cost 30-80 s per request
/// before the model wrote anything. Shown: every line up to the first type, each type's opening line and its stored
/// properties, and whole the members the request names (by name, or by a line number an error gives); the rest is one
/// outline line per member. An answer that needs a part not shown cannot be placed, and the caller asks with the whole file.
public enum FileExcerpt {
    public static let minimumCharacters = 12_000
    /// Measured 2026-11-25 on 14Translate's requests with Saluki 27B: 15,000-character files shown in part gave the same
    /// answers as whole (45→17 s, 29→20 s), but all three requests on the 38,000-character controller failed in part (one
    /// said nothing needed changing, two could not be placed) where the whole file had worked twice. Above this, whole.
    public static let maximumCharacters = 25_000
    /// Above this share of the file, the whole file is sent: an excerpt would save little.
    static let maximumShare = 0.6
    public static let gapMark = "⋯⋯ 省略"

    struct Member { let name: String; let range: ClosedRange<Int>; let header: String }

    /// The text to show for the file, or nil when the whole file should be sent.
    public static func excerpt(of content: String, instruction: String) -> String? {
        guard content.count >= minimumCharacters, content.count <= maximumCharacters else { return nil }
        let lines = content.components(separatedBy: "\n")
        let members = Self.members(in: lines)
        guard !members.isEmpty else { return nil }
        var keep = Set<Int>()
        // Everything before the first member's type: imports and the opening of the type.
        let firstType = lines.firstIndex { typeHeader($0) } ?? 0
        keep.formUnion(0...firstType)
        for (index, line) in lines.enumerated() where typeHeader(line) || storedProperty(line) && depth(before: index, lines) == 1 {
            keep.insert(index)
        }
        // Identifiers, also where Japanese text touches them (「splitTextを」).
        let identifier = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]{2,}"#)
        let words = Set(identifier.matches(in: instruction, range: NSRange(instruction.startIndex..., in: instruction))
            .compactMap { Range($0.range, in: instruction).map { String(instruction[$0]) } })
        let numbers = lineNumbers(in: instruction)
        var chosen = 0
        for member in members where words.contains(member.name) || numbers.contains(where: { member.range.contains($0 - 1) }) {
            keep.formUnion(member.range); chosen += 1
        }
        // A type the request names (「TranslationPair に text を足して」), whole when it is short (2026-11-25: shown only by
        // its first line, the model answered that nothing needed changing).
        for (index, line) in lines.enumerated() where typeHeader(line) {
            guard let name = typeName(line), words.contains(name) else { continue }
            var depth = 0, end = index
            while end < lines.count {
                depth += lines[end].filter { $0 == "{" }.count - lines[end].filter { $0 == "}" }.count
                if depth <= 0, lines[index...end].contains(where: { $0.contains("{") }) { break }
                end += 1
            }
            if end < lines.count, end - index <= 80 { keep.formUnion(index...end); chosen += 1 }
        }
        // A numbered line outside any member: a few lines around it.
        for number in numbers where !members.contains(where: { $0.range.contains(number - 1) }) && number - 1 < lines.count {
            keep.formUnion(max(0, number - 9)...min(lines.count - 1, number + 7))
        }
        guard chosen > 0 || !numbers.isEmpty else { return nil }
        // The type's closing lines, so a member added at its end has a place to go.
        for (index, line) in lines.enumerated() where line.hasPrefix("}") { keep.insert(index) }
        let shown = keep.sorted()
        let shownCharacters = shown.reduce(0) { $0 + lines[$1].count + 1 }
        guard Double(shownCharacters) <= Double(content.count) * maximumShare else { return nil }
        var out: [String] = []
        var previous = -1
        for index in shown {
            if index > previous + 1 {
                let hidden = members.filter { $0.range.lowerBound > previous && $0.range.lowerBound < index }.map(\.name)
                out.append("\(gapMark)(\(previous + 2)〜\(index) 行目\(hidden.isEmpty ? "" : ": " + hidden.joined(separator: "、")))")
            }
            out.append(lines[index])
            previous = index
        }
        if previous < lines.count - 1 { out.append("\(gapMark)(\(previous + 2)〜\(lines.count) 行目)") }
        let outline = members.map { "\($0.range.lowerBound + 1)行目 \($0.header.trimmingCharacters(in: .whitespaces))" }
        return """
        (このファイルは \(lines.count) 行あり長いので、目次と、依頼に関係する部分だけを示します。「\(gapMark)」の行はファイルにはありません。「いま」には示した行だけを使ってください。)
        目次:
        \(outline.joined(separator: "\n"))

        \(out.joined(separator: "\n"))
        """
    }

    /// Functions, initialisers and computed properties with a body, by the lines they span.
    static func members(in lines: [String]) -> [Member] {
        var result: [Member] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let name = memberName(line) else { index += 1; continue }
            var start = index
            while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("@")
                    || lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("///") { start -= 1 }
            var depth = 0, opened = false, end = index
            while end < lines.count {
                depth += lines[end].filter { $0 == "{" }.count - lines[end].filter { $0 == "}" }.count
                if lines[end].contains("{") { opened = true }
                if opened, depth <= 0 { break }
                // A stored property without a body.
                if !opened, end > index { end = index; break }
                end += 1
            }
            guard opened, end < lines.count else { index += 1; continue }
            result.append(Member(name: name, range: start...end, header: line))
            index = end + 1
        }
        return result
    }

    static func memberName(_ line: String) -> String? {
        if let range = line.range(of: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) {
            return line[range].split(separator: " ").last.map(String.init)
        }
        if line.range(of: #"^\s*((public|private|fileprivate|internal|override|convenience|required|nonisolated)\s+)*init[?!]?\s*\("#, options: .regularExpression) != nil {
            return "init"
        }
        if line.contains("{"), line.range(of: #"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)\s*:[^=]*\{\s*$"#, options: .regularExpression) != nil {
            return FunctionEdit.propertyName(line)
        }
        return nil
    }

    static func typeHeader(_ line: String) -> Bool {
        line.range(of: #"^\s*((public|private|fileprivate|internal|final|open)\s+)*(@\w+\s+)*(class|struct|enum|actor|extension)\s+\w"#,
                   options: .regularExpression) != nil
    }

    static func typeName(_ line: String) -> String? {
        guard let range = line.range(of: #"(class|struct|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) else { return nil }
        return line[range].split(separator: " ").last.map(String.init)
    }

    static func storedProperty(_ line: String) -> Bool {
        line.range(of: #"^\s*(@\w+(\([^)]*\))?\s+)*((public|private|fileprivate|internal|static|lazy|weak|nonisolated|let|var)\s+)*(var|let)\s+\w+"#,
                   options: .regularExpression) != nil && !line.trimmingCharacters(in: .whitespaces).hasSuffix("{")
    }

    static func depth(before index: Int, _ lines: [String]) -> Int {
        lines[..<index].reduce(0) { $0 + $1.filter { $0 == "{" }.count - $1.filter { $0 == "}" }.count }
    }

    /// Line numbers an error names: 「行129」, 「129行目」, 「File.swift:129」.
    static func lineNumbers(in text: String) -> [Int] {
        let patterns = [#"行\s*(\d+)"#, #"(\d+)\s*行目"#, #"\.swift:(\d+)"#]
        var found: [Int] = []
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text), let number = Int(text[range]), number > 0 { found.append(number) }
            }
        }
        return found
    }
}
