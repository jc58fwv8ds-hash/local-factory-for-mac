import Foundation

/// A screen using a property its project type does not have yet (2026-11-11: 14Translate's TranslationScreen used
/// TranslationController.speakerEnabled for the read-aloud switch it was asked for; the error named the screen, whose
/// repair could only rename, and nothing like it existed). When no member of the type resembles the missing name, the
/// type's own file is the one to change: the member is added there.
public enum MissingMemberRetarget {
    public static func retarget(_ diagnostics: [BuildFailureDiagnostic], rootURL: URL) -> [BuildFailureDiagnostic] {
        var added = Set<String>()
        var result: [BuildFailureDiagnostic] = []
        for diagnostic in diagnostics {
            guard let (type, member) = SDKMemberLookup.missingMember(in: diagnostic.message),
                  let file = declaringFile(of: type, under: rootURL), file != diagnostic.relativePath else {
                result.append(diagnostic); continue
            }
            let members = ProjectMemberLookup.members(of: type, projectRoot: rootURL)
            guard !members.contains(where: { resembles($0, member) }) else { result.append(diagnostic); continue }
            guard added.insert(type + "." + member).inserted else { continue }
            result.append(BuildFailureDiagnostic(
                validationKind: diagnostic.validationKind, relativePath: file, line: nil, column: nil,
                message: "\((diagnostic.relativePath as NSString).lastPathComponent) が \(type).\(member) を使っていますが、\(type) にまだありません。"
                    + "\(type) に \(member) を足してください(使い方: \(diagnostic.message))。"))
        }
        return result
    }

    static func declaringFile(of type: String, under root: URL) -> String? {
        TestFailureAnalyzer.swiftFiles(under: root).first { path in
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { return false }
            return text.range(of: #"\b(class|struct|actor|enum)\s+\#(type)\b"#, options: .regularExpression) != nil
        }
    }

    /// Shares a run of five letters, ignoring case (「isSpeakerOn」 resembles 「speakerEnabled」).
    static func resembles(_ name: String, _ missing: String) -> Bool {
        let a = name.lowercased(), b = Array(missing.lowercased())
        guard b.count >= 5 else { return a.contains(String(b)) }
        return (0...(b.count - 5)).contains { a.contains(String(b[$0..<($0 + 5)])) }
    }
}
