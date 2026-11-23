import Foundation

/// What a model bundled with the project says about its own prompt format (2026-11-16: asked to make 14Translate's
/// translations polite, the Factory wrote PLaMo's style as a tag of its own, `<|plamo:tag|>form<|plamo:msg|>polite`;
/// the model's file says it goes on the output, `<|plamo:key|>form<|plamo:val|>polite`). A GGUF file carries its chat
/// template, and some templates explain the format in `{# … #}` comments; those comments go with requests to code that
/// builds such prompts by hand.
public enum BundledModelNotes {
    /// The template comments of the GGUF files under the project, when its code writes special tokens (「<|…|>」) itself.
    public static func notes(rootURL: URL, limit: Int = 2_500) -> String? {
        let sources = TestFailureAnalyzer.swiftFiles(under: rootURL).filter { !$0.contains("Tests/") }
        guard sources.contains(where: { (try? String(contentsOf: rootURL.appendingPathComponent($0), encoding: .utf8))?
            .range(of: #"<\|[a-z_:]+\|>"#, options: .regularExpression) != nil }) else { return nil }
        for model in ggufFiles(under: rootURL) {
            guard let template = chatTemplate(of: model) else { continue }
            // Only the lines that write the format, in order (2026-11-16: with the template's comments, which also explain a
            // chat client's settings block, the writer mixed that block into a hand-written prompt).
            let writes = formatLines(template)
            guard writes.contains(where: { !$0.hasPrefix("(") }) else { continue }
            let bos = beginningToken(of: model)
            return "同梱のモデル(\(model.lastPathComponent))は、指示をこの順につないだ 1 本の文字列で受け取ります(モデルのファイルに入っている"
                + "組み立て方。改行は入れず、この中にない欄は作らない。値は + のあとの変数のところに入れる。"
                + "「くり返し」の間は一覧の数だけ書き、一覧が空なら書かない。「…のときだけ」の間は、その条件のときだけ書く。"
                + "一覧[-1] は一覧の最後(今の入力)、一覧[:-1] は最後より前(これまでのやりとり)):\n"
                + String(writes.joined(separator: "\n").prefix(limit))
                + (bos.map { token, added in "\nbos_token はこのモデルでは「\(token)」です。" + (added
                    ? "llama_tokenize などで文字列を言葉に分けるときに自動で付く(このモデルは add_bos_token = true)ので、文字列には書かないでください。"
                    : "自動では付かないので、文字列の先頭に「\(token)」と書いてください。") } ?? "")
        }
        return nil
    }

    /// The lines that write the format, with the loops and conditions around them (2026-11-17: shown only the writes, the
    /// writer took PLaMo's loop over the earlier turns, `for message in translation_messages[:-1]`, for a second input, and
    /// 14Translate translated the previous translation instead of what was just heard).
    static func formatLines(_ template: String) -> [String] {
        var kept: [String] = []
        // Index in `kept` of each open block, and whether a write is inside it.
        var open: [(index: Int, wrote: Bool)] = []
        for raw in template.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let body = line.replacingOccurrences(of: #"^\{[{%]-?\s*|\s*-?[}%]\}$"#, with: "", options: .regularExpression)
            if line.hasPrefix("{{"), line.contains("<|"), !line.contains("raise_exception") {
                kept.append(String(repeating: "  ", count: open.count) + body)
                for index in open.indices { open[index].wrote = true }
            } else if line.hasPrefix("{%"), body.hasPrefix("for ") || body.hasPrefix("if ") {
                let label = body.hasPrefix("for ") ? "(くり返し: \(body.dropFirst(4))" + ")" : "(\(body.dropFirst(3)) のときだけ)"
                open.append((kept.count, false))
                kept.append(String(repeating: "  ", count: open.count - 1) + label)
            } else if line.hasPrefix("{%"), body.hasPrefix("else") || body.hasPrefix("elif "), let last = open.last {
                kept.append(String(repeating: "  ", count: open.count - 1) + (body.hasPrefix("else") ? "(そうでないとき)" : "(\(body.dropFirst(5)) のとき)"))
                _ = last
            } else if line.hasPrefix("{%"), body.hasPrefix("endfor") || body.hasPrefix("endif"), let block = open.popLast() {
                if block.wrote {
                    kept.append(String(repeating: "  ", count: open.count) + (body.hasPrefix("endfor") ? "(くり返しここまで)" : "(ここまで)"))
                    if let parent = open.indices.last { open[parent].wrote = true }
                } else {
                    kept.removeSubrange(block.index...)
                }
            }
        }
        return kept
    }

    static func ggufFiles(under root: URL) -> [URL] {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        while let url = entries.nextObject() as? URL {
            if SourceFilePolicy.isExcludedDirectory(url.lastPathComponent) { entries.skipDescendants(); continue }
            if url.pathExtension == "gguf" { found.append(url) }
        }
        return found
    }

    /// The model's beginning token and whether its tokenizer adds it itself (2026-11-17: shown 「bos_token + …」, the writer
    /// put 「<s>」 in front of 14Translate's prompt; PLaMo's is 「<|plamo:bos|>」 and llama.cpp adds it already).
    public static func beginningToken(of file: URL) -> (token: String, added: Bool)? {
        guard let vocabulary = vocabulary(of: file), let bosID = vocabulary.bosID, bosID < vocabulary.tokens.count else { return nil }
        return (vocabulary.tokens[bosID], vocabulary.addBos)
    }

    /// The tokens of a GGUF file's vocabulary, its beginning token's id and whether the tokenizer adds it.
    public static func vocabulary(of file: URL) -> (tokens: [String], bosID: Int?, addBos: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 << 20) else { return nil }
        var reader = Reader(data: data)
        guard reader.bytes(4) == Data("GGUF".utf8), let version = reader.u32(), version >= 2,
              reader.u64() != nil, let count = reader.u64() else { return nil }
        var tokens: [String] = []
        var bosID: Int?
        var addBos = true
        for _ in 0..<count {
            guard let key = reader.string(), let type = reader.u32() else { break }
            if key == "tokenizer.ggml.tokens", type == 9, let inner = reader.u32(), inner == 8, let n = reader.u64() {
                for _ in 0..<n { guard let token = reader.string() else { return nil }; tokens.append(token) }
            } else if key == "tokenizer.ggml.bos_token_id", type == 4, let id = reader.u32() {
                bosID = Int(id)
            } else if key == "tokenizer.ggml.add_bos_token", type == 7, let flag = reader.bytes(1) {
                addBos = flag.first != 0
            } else if !reader.skip(type: type) { break }
        }
        return tokens.isEmpty ? nil : (tokens, bosID, addBos)
    }

    /// `tokenizer.chat_template` from a GGUF file's header, read without loading the model.
    public static func chatTemplate(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 48 << 20) else { return nil }
        var reader = Reader(data: data)
        guard reader.bytes(4) == Data("GGUF".utf8), let version = reader.u32(), version >= 2,
              reader.u64() != nil, let count = reader.u64() else { return nil }
        for _ in 0..<count {
            guard let key = reader.string(), let type = reader.u32() else { return nil }
            if key == "tokenizer.chat_template", type == 8 { return reader.string() }
            guard reader.skip(type: type) else { return nil }
        }
        return nil
    }

    struct Reader {
        let data: Data
        var at = 0
        mutating func bytes(_ n: Int) -> Data? {
            guard n >= 0, at + n <= data.count else { return nil }
            defer { at += n }
            return data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + n))
        }
        mutating func u32() -> UInt32? { bytes(4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } } }
        mutating func u64() -> UInt64? { bytes(8).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } } }
        mutating func string() -> String? {
            guard let n = u64(), n < 64 << 20, let raw = bytes(Int(n)) else { return nil }
            return String(decoding: raw, as: UTF8.self)
        }
        /// Moves past one value of a GGUF type (0-12).
        mutating func skip(type: UInt32) -> Bool {
            let sizes: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
            if let size = sizes[type] { return bytes(size) != nil }
            if type == 8 { return string() != nil }
            guard type == 9, let inner = u32(), let n = u64() else { return false }
            if let size = sizes[inner] { return n < UInt64(Int.max / max(size, 1)) && bytes(Int(n) * size) != nil }
            for _ in 0..<n { guard skip(type: inner) else { return false } }
            return true
        }
    }
}
