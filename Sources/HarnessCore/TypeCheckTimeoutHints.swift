import Foundation

/// 「unable to type-check this expression in reasonable time」 hides the real error: a name that does not exist inside
/// a long SwiftUI expression (2026-11-23: 14Translate's subtitle list used `.scrollToID(…)` and `controller.translations`,
/// neither real; two writers could not fix it from the message alone, and the batch stopped).
public enum TypeCheckTimeoutHints {
    public static let mark = "式の中に実在しない名前がある"

    public static func hint(messages: [String], lines: [String], errorLines: [Int], projectRoot: URL,
                            sdkDeclares: (String) -> Bool = { SDKSwiftInterfaceLookup.shared.declaresFunction($0) }) -> String? {
        guard messages.contains(where: { $0.contains("unable to type-check this expression") }) else { return nil }
        let texts = TestFailureAnalyzer.swiftFiles(under: projectRoot).compactMap {
            try? String(contentsOf: projectRoot.appendingPathComponent($0), encoding: .utf8)
        }
        let whole = lines.joined(separator: "\n")
        var found: [String] = []
        for start in errorLines where start >= 1 && start <= lines.count {
            let region = expression(from: start, in: lines)
            for name in matches(#"(?m)(?:^\s*|\))\.([a-z]\w*)\s*\("#, in: region) where !found.contains(where: { $0.hasPrefix("- .\(name)(") }) {
                if texts.contains(where: { $0.range(of: #"func\s+\#(name)\b"#, options: .regularExpression) != nil }) { continue }
                if sdkDeclares(name) { continue }
                found.append("- .\(name)(…): Apple の部品にも、このプロジェクトにもありません")
            }
            for pair in pairs(#"\b([a-z]\w*)\.([a-z]\w*)\b"#, in: region) {
                guard let type = declaredType(of: pair.0, in: whole) else { continue }
                let members = ProjectMemberLookup.members(of: type, projectRoot: projectRoot)
                let names = members.map { String($0.prefix { $0 != "(" }) }
                guard !members.isEmpty, !names.contains(pair.1) else { continue }
                let line = "- \(pair.0).\(pair.1): \(type) に \(pair.1) はありません(あるのは: \(members.prefix(20).joined(separator: ", ")))"
                if !found.contains(line) { found.append(line) }
            }
        }
        guard !found.isEmpty else {
            return "直し方(型を確かめきれないエラー): 長い式の中の名前が実在するかを確かめ、式を小さな View や関数に分けてください。"
        }
        var text = "直し方(型を確かめきれないエラー): このエラーは、\(mark)ときに出ます。次の名前は実在しないので、実在するものに置き換えてください:\n"
            + found.prefix(6).joined(separator: "\n")
        if found.contains(where: { $0.lowercased().contains("scroll") }) {
            text += "\n一覧を一番下まで自動で送るには、ScrollViewReader { proxy in ScrollView { … } } で包み、"
                + ".onChange(of: 一覧.count) { _, _ in if let last = 一覧.last { proxy.scrollTo(last.id, anchor: .bottom) } } と書きます。"
        }
        return text
    }

    /// The view body (or view-building function) the error line is in, whole: the compiler names one line of the long
    /// expression, while the name that does not exist is often in a modifier further down.
    static func expression(from start: Int, in lines: [String]) -> String {
        let head = (0..<start).reversed().first {
            lines[$0].range(of: #"(var\s+\w+\s*:\s*some\s+View|func\s+\w+.*->\s*some\s+View)"#, options: .regularExpression) != nil
        } ?? max(0, start - 21)
        var depth = 0
        var taken: [String] = []
        for line in lines[head...].prefix(200) {
            taken.append(line)
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if depth <= 0 && taken.count > 1 && line.contains("}") { break }
        }
        return taken.joined(separator: "\n")
    }

    static func declaredType(of name: String, in text: String) -> String? {
        // `var x: Type` or `var x = Type(…)`.
        if let range = text.range(of: #"\b(var|let)\s+\#(name)\s*:\s*([A-Z]\w*)"#, options: .regularExpression) {
            return text[range].components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
        }
        guard let range = text.range(of: #"\b(var|let)\s+\#(name)\s*=\s*([A-Z]\w*)\("#, options: .regularExpression) else { return nil }
        return text[range].components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "(", with: "")
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        pairs(pattern, in: text, groups: 1).map(\.0)
    }

    static func pairs(_ pattern: String, in text: String, groups: Int = 2) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), groups > 1 ? ns.substring(with: $0.range(at: 2)) : "")
        }
    }
}

extension SDKSwiftInterfaceLookup {
    /// Whether any framework of the SDK declares a function (or modifier) of this name.
    public func declaresFunction(_ name: String) -> Bool {
        loadInterfaces().contains { $0.text.contains("func \(name)(") || $0.text.contains("func \(name)<") }
    }
}
