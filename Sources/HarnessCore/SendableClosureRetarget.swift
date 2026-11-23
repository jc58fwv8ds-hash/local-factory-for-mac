import Foundation

/// A closure handed to a project actor's method whose parameter is not `@Sendable` (2026-11-19: 14Translate's translator, an
/// actor, took `onSegmentComplete: @escaping (String) -> Void`; the caller got 「sending value of non-Sendable type
/// '(String) -> Void' risks causing data races」 and six repairs of the caller, told not to change the declaration, could not
/// fix it). The declaring file is the one to change: the parameter becomes `@Sendable`.
public enum SendableClosureRetarget {
    public static func retarget(_ diagnostics: [BuildFailureDiagnostic], rootURL: URL) -> [BuildFailureDiagnostic] {
        var result: [BuildFailureDiagnostic] = []
        var added = Set<String>()
        for diagnostic in diagnostics {
            guard let closureType = closureType(in: diagnostic.message), let line = diagnostic.line,
                  let source = try? String(contentsOf: rootURL.appendingPathComponent(diagnostic.relativePath), encoding: .utf8) else {
                result.append(diagnostic); continue
            }
            let lines = source.components(separatedBy: "\n")
            let window = lines[max(0, line - 4)..<min(lines.count, line + 2)].joined(separator: "\n")
            guard let found = declaration(calledIn: window, closureType: closureType, rootURL: rootURL) else {
                result.append(diagnostic); continue
            }
            guard added.insert(found.file + ":\(found.line)").inserted else { continue }
            result.append(BuildFailureDiagnostic(
                validationKind: diagnostic.validationKind, relativePath: found.file, line: found.line, column: nil,
                message: "\((diagnostic.relativePath as NSString).lastPathComponent) の \(line) 行目から \(found.name) に渡すクロージャで "
                    + "「\(diagnostic.message.prefix(120))」になっています。この関数の宣言の引数の型 \(closureType) を "
                    + "@Sendable \(closureType) にしてください(@escaping はそのまま)。呼ぶ側ではなく、この宣言を変えれば直ります。"))
        }
        return result
    }

    /// `(String) -> Void` from 「sending value of non-Sendable type '(String) -> Void'」.
    static func closureType(in message: String) -> String? {
        guard message.contains("non-Sendable type"),
              let range = message.range(of: #"non-Sendable type '(\([^']*\)\s*(async\s*)?(throws\s*)?->\s*[^']+)'"#, options: .regularExpression) else { return nil }
        return String(message[range].split(separator: "'", omittingEmptySubsequences: false)[1])
    }

    /// The project function called in the lines whose declaration takes that closure type without `@Sendable`.
    static func declaration(calledIn window: String, closureType: String, rootURL: URL) -> (file: String, line: Int, name: String)? {
        let names = Set(ProjectCallLookup.calledNames(window))
        let bare = closureType.replacingOccurrences(of: " ", with: "")
        for path in TestFailureAnalyzer.swiftFiles(under: rootURL) where !path.contains("Tests/") {
            guard let text = try? String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                guard let name = ProjectCallLookup.declaredName(line.trimmingCharacters(in: .whitespaces)), names.contains(name) else { continue }
                let squeezed = line.replacingOccurrences(of: " ", with: "")
                guard squeezed.contains(bare), !squeezed.contains("@Sendable" + bare) else { continue }
                return (path, index + 1, name)
            }
        }
        return nil
    }
}
