import Foundation

extension StructuredEditBatch {
    /// Deterministic anchor diagnostics for a rejected batch: for every replace_exact edit whose anchor does not occur
    /// exactly once (applying earlier edits first, as `proposedContents` does), how often and where it occurs.
    /// Contains only the model's own anchor and line numbers of the offered files — never test sources.
    public func anchorReport(originals: [String: String]) -> [String] {
        var contents = originals
        var report: [String] = []
        for (index, edit) in edits.enumerated() where edit.operation == "replace_exact" {
            guard let source = contents[edit.file], !edit.expected_old_text.isEmpty else { continue }
            var lines: [Int] = []
            var searchRange = source.startIndex..<source.endIndex
            while let found = source.range(of: edit.expected_old_text, range: searchRange) {
                lines.append(source[..<found.lowerBound].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) })
                searchRange = found.upperBound..<source.endIndex
            }
            let head = edit.expected_old_text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if lines.count == 1 {
                contents[edit.file] = source.replacingOccurrences(of: edit.expected_old_text, with: edit.new_text)
            } else if lines.isEmpty {
                report.append("edit \(index + 1) (\(edit.file)): expected_old_text starting \"\(head.prefix(80))\" occurs 0 times; "
                    + Self.firstDifference(anchor: edit.expected_old_text, in: source))
            } else {
                report.append("edit \(index + 1) (\(edit.file)): expected_old_text starting \"\(head.prefix(80))\" occurs \(lines.count) times (lines \(lines.prefix(5).map(String.init).joined(separator: ", "))); include more surrounding lines so it occurs exactly once")
            }
        }
        return report
    }

    /// Where a non-matching anchor stops matching: the longest leading run of its lines found in the file and the first
    /// differing line (file vs. anchor), or the file line that matches its first line only when indentation is ignored.
    static func firstDifference(anchor: String, in source: String) -> String {
        func show(_ line: String) -> String { "`" + String(line.prefix(120)) + "`" }
        func lineNumber(_ index: String.Index) -> Int { source[..<index].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) } }
        let anchorLines = anchor.components(separatedBy: "\n"), sourceLines = source.components(separatedBy: "\n")
        for count in stride(from: anchorLines.count - 1, through: 1, by: -1) {
            guard let found = source.range(of: anchorLines[0..<count].joined(separator: "\n")) else { continue }
            let start = lineNumber(found.lowerBound), next = start - 1 + count
            let fileLine = next < sourceLines.count ? sourceLines[next] : "(end of file)"
            // The current lines themselves: a model that remembers the file before its own earlier edit (recorded c2-10
            // compiler repair) repeats the stale anchor when told only which line differs.
            let excerpt = (start - 1..<min(sourceLines.count, start - 1 + min(anchorLines.count + 3, 25)))
                .map { "\($0 + 1): \(sourceLines[$0])" }.joined(separator: "\n")
            return "its first \(count) of \(anchorLines.count) lines match at line \(start); line \(count + 1) differs: file has "
                + show(fileLine) + ", you wrote " + show(anchorLines[count]) + ". Copy the lines exactly from the file. "
                + "Current file lines (numbers are not part of the file):\n" + excerpt
        }
        let first = anchorLines[0].trimmingCharacters(in: .whitespaces)
        if !first.isEmpty, let line = sourceLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == first }) {
            return "its first line matches line \(line + 1) only when indentation is ignored: file has " + show(sourceLines[line])
                + ". Copy the indentation exactly."
        }
        return "its first line " + show(anchorLines[0]) + " does not occur in the file. Copy anchor lines exactly from the file."
    }
}
