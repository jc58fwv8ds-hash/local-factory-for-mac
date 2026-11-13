import Foundation

/// The files xcodebuild lists as failed to compile, each with the error lines of the log (2026-11-12).
public enum CompileFailureFiles {
    public static func diagnostics(output: String, rootURL: URL, kind: ProjectValidationKind) -> [BuildFailureDiagnostic] {
        let root = rootURL.standardizedFileURL.path + "/"
        let errors = output.components(separatedBy: "\n").filter { $0.contains("error:") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .prefix(8)
        guard let regex = try? NSRegularExpression(pattern: #"SwiftCompile \S+ \S+ (?:Compiling\\ \S+ )?(/.+?\.swift)"#) else { return [] }
        var files: [String] = []
        for line in output.components(separatedBy: "\n") {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            let path = line[range].replacingOccurrences(of: "\\ ", with: " ")
            guard path.hasPrefix(root) else { continue }
            let relative = String(path.dropFirst(root.count))
            if !files.contains(relative) { files.append(relative) }
        }
        return files.map { file in
            BuildFailureDiagnostic(validationKind: kind, relativePath: file, line: nil, column: nil,
                                   message: "このファイルのコンパイルに失敗しました。エラー: " + errors.joined(separator: " / "))
        }
    }
}
