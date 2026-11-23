import Foundation

/// Stand-ins still in the files a run saved, before it says the work is done (2026-11-17: 14Translate's fallback listener
/// sent the fixed text 「[音声認識不可、代替処理中]」 to the translator under 「// Generate placeholder text」; the writer was told
/// once, wrote it again, and the run reported 「できました。ビルドとテストに合格しました」).
public enum UnfinishedCodeCheck {
    /// One diagnostic per saved file with lines `UnfinishedCode` finds that were not in the file before the run.
    public static func diagnostics(rootURL: URL, savedFiles: [String], before: (String) -> String?) -> [BuildFailureDiagnostic] {
        Array(Set(savedFiles)).sorted().compactMap { path in
            guard path.hasSuffix(".swift"), !path.contains("Tests/"),
                  let text = try? String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8) else { return nil }
            let found = UnfinishedCode.findings(in: text, previous: before(path))
            guard let first = found.first else { return nil }
            let lines = text.components(separatedBy: "\n")
            let line = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == first }.map { $0 + 1 }
            return BuildFailureDiagnostic(validationKind: .build, relativePath: path, line: line, column: nil,
                                          message: message(found))
        }
    }

    static func message(_ found: [String]) -> String {
        "このファイルに、まだ本当には動かない仮の作りが残っています(" + found.prefix(3).map { "「\($0.prefix(80))」" }.joined(separator: "、")
            + ")。決まった文を返す・何もせず印字するだけ・あとで作るとした所を残さず、頼まれたことが実際に動く形にしてください。"
            + "仮の文やコメントを消すだけ、言い換えるだけにはしないでください。"
    }

    /// The file as the last commit has it, or nil when it is new or the folder is not a repository.
    public static func committed(_ path: String, root: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root, "show", "HEAD:" + path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
