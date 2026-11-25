import Foundation

/// A file request's instruction without what does not concern that file (2026-11-25, the user: 「指示の短縮」). On
/// 2026-11-23 the instruction of each 14Translate repair ran to 3,000-11,000 characters, read again on every request:
/// - the SDK reference's list of the framework's other types (60 lines, e.g. hover effects and timeline schedules for a
///   subtitle fix), kept only when the request is about using a new Apple type;
/// - findings about other files of the project, which the instruction itself says not to act on here;
/// - more than the last 12 lines of the app's output.
public enum InstructionTrim {
    static let otherTypesHeader = "同じフレームワークの型:"
    static let findingsHeader = "調べてわかったこと"
    static let outputHeader = "アプリの出力"
    static let keptOutputLines = 12

    public static func shorten(_ instruction: String, targetPath: String) -> String {
        let target = (targetPath as NSString).lastPathComponent
        var out: [String] = []
        var section: String?
        var outputLines: [String] = []
        let repair = instruction.hasPrefix("次のビルドエラーを解消") || instruction.hasPrefix("次のテスト")
        func flushOutput() {
            if outputLines.count > keptOutputLines { out.append("(前略: \(outputLines.count - keptOutputLines) 行)") }
            out += outputLines.suffix(keptOutputLines)
            outputLines = []
        }
        for line in instruction.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A new section starts at its header; a blank line ends the output and the type list.
            if trimmed.hasPrefix(otherTypesHeader) { section = otherTypesHeader; if !repair { out.append(line) }; continue }
            if trimmed.hasPrefix(findingsHeader) { flushOutput(); section = findingsHeader; out.append(line); continue }
            if trimmed.contains(outputHeader), trimmed.hasSuffix(":") || trimmed.hasSuffix("):") {
                flushOutput(); section = outputHeader; out.append(line); continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("参考(") {
                if section == outputHeader { flushOutput() }
                if section == otherTypesHeader || section == outputHeader || trimmed.hasPrefix("参考(") { section = nil }
                out.append(line); continue
            }
            switch section {
            case otherTypesHeader:
                if !repair { out.append(line) }
            case outputHeader:
                outputLines.append(line)
            case findingsHeader:
                // A finding that starts with another file of the project.
                if let path = trimmed.split(separator: " ").first, path.hasSuffix(".swift"),
                   (String(path) as NSString).lastPathComponent != target {
                    continue
                }
                out.append(line)
            default:
                out.append(line)
            }
        }
        flushOutput()
        return out.joined(separator: "\n")
    }
}
