import Foundation

/// Rewrites text in a .docx into a NEW file (file operations stage 5, 2026-10-11). Only the text inside the runs of
/// word/document.xml changes, so styles, tables, images and everything else stay. A replacement inside one run keeps that
/// run's formatting; one that spans runs goes into the first of them (its formatting) and empties the others.
enum WordEditor {
    struct Edit: Codable, Equatable, Sendable {
        var find: String
        var replace: String
    }

    struct Change: Equatable, Sendable {
        let before: String
        let after: String
    }

    enum Failure: LocalizedError {
        case unreadable(String), notFound(String), write(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "「\(name)」を開けませんでした"
            case .notFound(let text): "「\(text.prefix(30))」が文書の中に見つかりません"
            case .write(let detail): "新しいファイルを書き出せませんでした(\(detail))"
            }
        }
    }

    /// The paragraphs' plain text, numbered, for the model to quote exactly.
    static func paragraphs(of source: URL) throws -> [String] {
        let work = try unzipped(source)
        defer { try? FileManager.default.removeItem(at: work) }
        let xml = try String(contentsOf: work.appendingPathComponent("word/document.xml"), encoding: .utf8)
        return paragraphRanges(in: xml).map { text(of: String(xml[$0])) }.filter { !$0.isEmpty }
    }

    /// Applies the edits; writes `output` (never the source). Returns each changed paragraph before and after.
    static func apply(_ edits: [Edit], to source: URL, output: URL) throws -> [Change] {
        let work = try unzipped(source)
        defer { try? FileManager.default.removeItem(at: work) }
        let documentURL = work.appendingPathComponent("word/document.xml")
        var xml = try String(contentsOf: documentURL, encoding: .utf8)
        var changes: [Change] = []
        for edit in edits where !edit.find.isEmpty {
            guard let range = paragraphRanges(in: xml).first(where: { text(of: String(xml[$0])).contains(edit.find) }) else {
                throw Failure.notFound(edit.find)
            }
            let paragraph = String(xml[range])
            let before = text(of: paragraph)
            let rewritten = replacing(edit.find, with: edit.replace, in: paragraph)
            xml.replaceSubrange(range, with: rewritten)
            changes.append(.init(before: before, after: text(of: rewritten)))
        }
        try xml.write(to: documentURL, atomically: true, encoding: .utf8)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.write("同じ名前のファイルがあります") }
        guard run("/usr/bin/zip", ["-q", "-X", "-r", output.path, "."], in: work) else { throw Failure.write("zip") }
        do {
            try OfficePackageCheck.verify(source: source, output: output, edited: ["word/document.xml"])
        } catch {
            try? FileManager.default.removeItem(at: output)   // a file this call just wrote, never the user's
            throw error
        }
        return changes
    }

    static func paragraphRanges(in xml: String) -> [Range<String.Index>] {
        // Innermost paragraphs only: a text box's paragraphs sit inside a paragraph of the body, and a plain
        // `<w:p>.*?</w:p>` would end the outer one at the inner one's end tag (2026-10-12 review).
        guard let regex = try? NSRegularExpression(pattern: #"<w:p[ >](?:(?!<w:p[ >]).)*?</w:p>"#, options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { Range($0.range, in: xml) }
    }

    static func textRanges(in paragraph: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: #"(<w:t(?: [^>]*)?>)(.*?)(</w:t>)"#, options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: paragraph, range: NSRange(paragraph.startIndex..., in: paragraph)).compactMap { Range($0.range(at: 2), in: paragraph) }
    }

    static func text(of paragraph: String) -> String {
        textRanges(in: paragraph).map { unescape(String(paragraph[$0])) }.joined()
    }

    /// Puts the new text where the old text was, keeping the formatting of the run where it starts.
    static func replacing(_ find: String, with replacement: String, in paragraph: String) -> String {
        let ranges = textRanges(in: paragraph)
        let pieces = ranges.map { unescape(String(paragraph[$0])) }
        let joined = pieces.joined()
        guard let hit = joined.range(of: find) else { return paragraph }
        let startOffset = joined.distance(from: joined.startIndex, to: hit.lowerBound)
        let endOffset = joined.distance(from: joined.startIndex, to: hit.upperBound)
        // Each run covers [lower, upper) of the paragraph's text; the first run that overlaps the hit gets the new text.
        var newPieces = pieces, lower = 0, placed = false
        for (index, piece) in pieces.enumerated() {
            let upper = lower + piece.count
            defer { lower = upper }
            guard lower < endOffset, upper > startOffset else { continue }
            let tail = upper > endOffset ? String(piece.suffix(upper - endOffset)) : ""
            newPieces[index] = placed ? tail : String(piece.prefix(max(0, startOffset - lower))) + replacement + tail
            placed = true
        }
        var result = paragraph
        for (index, range) in ranges.enumerated().reversed() where newPieces[index] != pieces[index] {
            result.replaceSubrange(range, with: escape(newPieces[index]))
        }
        // Text with leading/trailing spaces needs xml:space="preserve" on its <w:t>.
        return result.replacingOccurrences(of: "<w:t>", with: "<w:t xml:space=\"preserve\">")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func outputURL(for source: URL) -> URL {
        let folder = source.deletingLastPathComponent(), base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(base)_編集済み.docx"), n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)_編集済み \(n).docx"); n += 1
        }
        return candidate
    }

    private static func unzipped(_ source: URL) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard run("/usr/bin/unzip", ["-q", source.path, "-d", work.path], in: work),
              FileManager.default.fileExists(atPath: work.appendingPathComponent("word/document.xml").path) else {
            try? FileManager.default.removeItem(at: work)
            throw Failure.unreadable(source.lastPathComponent)
        }
        return work
    }

    private static func run(_ tool: String, _ arguments: [String], in directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
