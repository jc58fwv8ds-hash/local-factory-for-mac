import Foundation

/// The project file that declares a type named in a crash report (2026-11-11).
public enum DeviceCrashFile {
    public static func declaring(_ type: String, under root: URL) -> String? {
        let pattern = #"(class|struct|actor|enum|extension)\s+"# + NSRegularExpression.escapedPattern(for: type) + #"\b"#
        return TestFailureAnalyzer.swiftFiles(under: root).filter { !$0.contains("Tests/") }.first { path in
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { return false }
            return text.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
