import Foundation

/// For 「type 'X' has no member 'y'」 on an Apple Swift type: the real functions and properties of X's framework whose names
/// share a word with 'y', with the type they belong to (2026-11-17: asked to install the English speech data, the local model
/// wrote `SpeechTranscriber.downloadLocale(…)` eight times and gave up; the real way is
/// `AssetInventory.assetInstallationRequest(supporting:)` then `downloadAndInstall()`, on other types, so the declaration of
/// SpeechTranscriber alone never showed it).
extension SDKSwiftInterfaceLookup {
    public func nearMembers(for message: String, limit: Int = 10) -> String? {
        guard let (type, member) = SDKMemberLookup.missingMember(in: message) else { return nil }
        let all = loadInterfaces()
        // A type inside another (`SpeechTranscriber.Preset`): everything it has, which is short (2026-11-17: the model wrote
        // `.general`; the real presets are `.transcription`, `.progressiveTranscription`, …).
        if type.contains("."), let nested = all.lazy.compactMap({ Self.nestedDeclaration(of: type, in: $0.text) }).first {
            return "\(type) に「\(member)」はありません。\(type) に実在するもの(SDK の宣言):\n" + nested
        }
        let words = Self.words(member)
        guard !words.isEmpty else { return nil }
        // The framework that declares the type: in its Swift interface, or, for an Objective-C class such as
        // SFSpeechRecognizer, in its headers.
        guard let home = all.first(where: { Self.declaration(of: type, in: $0.text, maximumLines: 2) != nil })
            ?? all.first(where: { declaresInHeaders(type, framework: $0.framework) }) else { return nil }
        var found: [(words: [String], line: String)] = []
        var owner = ""
        for raw in home.text.components(separatedBy: "\n") {
            if let name = Self.typeLines(in: raw).first.flatMap(Self.typeName) { owner = name; continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.range(of: #"^(@\w+ )*(final )?(public|open) (static |class |final )*(func|var|let|init)\b"#, options: .regularExpression) != nil
            else { continue }
            let name = Self.memberName(line).lowercased()
            let matched = words.filter { name.contains($0) }
            guard !matched.isEmpty else { continue }
            let entry = owner + ": " + Self.plain(line).replacingOccurrences(of: " {", with: "")
            if !found.contains(where: { $0.line == entry }) { found.append((matched, String(entry.prefix(220)))) }
        }
        guard !found.isEmpty else { return nil }
        // Those sharing every word first, then each word in turn, so a rare word (download) is not crowded out by a common one.
        var best = found.filter { $0.words.count == words.count && words.count > 1 }.map(\.line)
        let queues = words.map { word in found.filter { $0.words.contains(word) }.map(\.line) }
        var index = 0
        while best.count < limit, queues.contains(where: { $0.count > index }) {
            for queue in queues where queue.count > index && best.count < limit && !best.contains(queue[index]) { best.append(queue[index]) }
            index += 1
        }
        // How to get the types those belong to (`downloadAndInstall()` is on the request `AssetInventory` makes).
        let owners = Set(best.compactMap { $0.components(separatedBy: ": ").first }).subtracting([type])
        owner = ""
        for raw in home.text.components(separatedBy: "\n") where best.count < limit + 4 {
            if let name = Self.typeLines(in: raw).first.flatMap(Self.typeName) { owner = name; continue }
            let line = Self.plain(raw.trimmingCharacters(in: .whitespaces)).replacingOccurrences(of: " {", with: "")
            guard line.contains(" func "), owners.contains(where: { line.contains("-> " + $0) }) else { continue }
            let entry = owner + ": " + line
            if !best.contains(entry) { best.append(String(entry.prefix(220))) }
        }
        return "\(type) に「\(member)」はありません。\(home.framework) にある、名前の近い本物の関数・プロパティ(型: 宣言)。"
            + "別の型のものなら、その型を使って書いてください:\n" + best.joined(separator: "\n")
    }

    func declaresInHeaders(_ type: String, framework: String) -> Bool {
        guard let sdk = sdkPathValue() else { return false }
        let headers = URL(fileURLWithPath: sdk).appendingPathComponent("System/Library/Frameworks/\(framework).framework/Headers")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: headers.path)) ?? []
        return files.contains { file in
            file.hasSuffix(".h") && ((try? String(contentsOf: headers.appendingPathComponent(file), encoding: .utf8))?
                .contains("@interface \(type) ") ?? false)
        }
    }

    /// The member lines of `Outer.Inner`, declared inside Outer's block.
    static func nestedDeclaration(of type: String, in interface: String, maximumLines: Int = 20) -> String? {
        let parts = type.split(separator: ".").map(String.init)
        guard parts.count == 2 else { return nil }
        let lines = interface.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard typeLines(in: lines[index]).first.flatMap(typeName) == parts[0] else { continue }
            var depth = 0
            var cursor = index
            repeat {
                let line = lines[cursor]
                if depth >= 1, line.range(of: #"^\s+(public |open )(final )?(struct|enum|class) "# + parts[1] + #"\b"#, options: .regularExpression) != nil {
                    var kept: [String] = []
                    for inner in lines[(cursor + 1)...] {
                        let trimmed = inner.trimmingCharacters(in: .whitespaces)
                        if trimmed == "}" || kept.count >= maximumLines { break }
                        if trimmed.hasPrefix("public ") || trimmed.hasPrefix("case ") { kept.append(plain(trimmed)) }
                    }
                    return kept.isEmpty ? nil : kept.joined(separator: "\n")
                }
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                cursor += 1
            } while depth > 0 && cursor < lines.count
        }
        return nil
    }

    /// The words of a camel-case name, four letters or more, lower-cased (`downloadLocale` → download, locale).
    static func words(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in name {
            if character.isUppercase, !current.isEmpty { words.append(current); current = "" }
            current.append(character)
        }
        words.append(current)
        return words.map { $0.lowercased() }.filter { $0.count >= 4 }
    }

    static func memberName(_ line: String) -> String {
        guard let range = line.range(of: #"\b(func|var|let) [A-Za-z_][A-Za-z0-9_]*"#, options: .regularExpression) else {
            return line.contains("init") ? "init" : ""
        }
        return String(line[range].split(separator: " ").last ?? "")
    }
}
