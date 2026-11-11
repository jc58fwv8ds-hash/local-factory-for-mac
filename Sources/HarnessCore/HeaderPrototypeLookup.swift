import Foundation

/// The C declarations of the functions an erroring line calls, read from the headers of the parts added to the project
/// (2026-11-10: 14Translate's translator calls llama.cpp; the local model passed too few arguments and Int32 for Bool,
/// and only the declaration says what is right).
public enum HeaderPrototypeLookup {
    /// Up to `limit` declarations for the C functions called on the given source lines.
    public static func prototypes(forLines lines: [String], projectRoot: URL, limit: Int = 4) -> [String] {
        let names = Array(NSOrderedSet(array: lines.flatMap(calledNames))).compactMap { $0 as? String }
        guard !names.isEmpty else { return [] }
        let headers = headerTexts(under: projectRoot)
        var found: [String] = []
        for name in names {
            for header in headers {
                if let declaration = declaration(of: name, in: header) { found.append(declaration); break }
            }
            if found.count >= limit { break }
        }
        return found
    }

    /// C-style names called on a line (lowercase with an underscore, as C libraries name things).
    static func calledNames(in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b([a-z][a-z0-9]*_[a-z0-9_]+)\s*\("#) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
            Range($0.range(at: 1), in: line).map { String(line[$0]) }
        }
    }

    /// The declaration of the function in the header, joined onto one line.
    static func declaration(of name: String, in header: String) -> String? {
        guard let start = header.range(of: #"[^\n;{}]*\b\#(name)\s*\("#, options: .regularExpression),
              let end = header[start.lowerBound...].firstIndex(of: ";") else { return nil }
        let text = header[start.lowerBound...end]
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.count <= 400 ? text : nil
    }

    static func headerTexts(under root: URL) -> [String] {
        let fileManager = FileManager.default
        guard let entries = fileManager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var texts: [String] = []
        var seen = Set<String>()
        while let url = entries.nextObject() as? URL {
            let name = url.lastPathComponent.lowercased()
            if ["build", "deriveddata", ".build"].contains(name) || name.hasSuffix(".dsym") || name.contains("simulator") {
                entries.skipDescendants(); continue
            }
            // One copy of each header (an xcframework holds the same header once per platform).
            guard url.pathExtension == "h", seen.insert(url.lastPathComponent).inserted,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            texts.append(text)
            if texts.count >= 200 { break }
        }
        return texts
    }
}
