import Foundation

/// 「invalid redeclaration of 'X'」 pointed at the file the duplicate came from (2026-11-10: the model building
/// 14Translate's TranslationScreen wrote TranslationController into it again; the error named the original file, whose
/// repair changed nothing). The newest file that declares X is the one to change: X is removed there and the existing one used.
public enum RedeclarationRetarget {
    static let pattern = try! NSRegularExpression(pattern: #"invalid redeclaration of '(\w+)'"#)

    public static func retarget(_ diagnostics: [BuildFailureDiagnostic], rootURL: URL) -> [BuildFailureDiagnostic] {
        diagnostics.map { diagnostic in
            let message = diagnostic.message
            guard let match = pattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let name = Range(match.range(at: 1), in: message).map({ String(message[$0]) }) else { return diagnostic }
            let declarers = TestFailureAnalyzer.swiftFiles(under: rootURL).filter { path in
                guard let text = try? String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8) else { return false }
                return text.range(of: #"\b(class|struct|enum|actor|protocol)\s+\#(name)\b"#, options: .regularExpression) != nil
            }
            guard declarers.count >= 2 else { return diagnostic }
            func modified(_ path: String) -> Date {
                (try? rootURL.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            }
            let newest = declarers.max { modified($0) < modified($1) }!
            let others = declarers.filter { $0 != newest }.map { ($0 as NSString).lastPathComponent }
            return BuildFailureDiagnostic(
                validationKind: diagnostic.validationKind, relativePath: newest, line: nil, column: nil,
                message: "'\(name)' がこのファイルと \(others.joined(separator: "、")) の両方で宣言されています。このファイルの \(name) の宣言を"
                    + "まるごと消し、\(others.first ?? "既存のファイル") にある \(name) をそのまま使ってください(invalid redeclaration of '\(name)')。")
        }
    }
}
