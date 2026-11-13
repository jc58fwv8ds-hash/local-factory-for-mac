import Foundation

/// What the app writes while it runs on the iPhone (2026-11-13, 14Translate translated for a moment and stopped, and nothing
/// in the code said why). After the app is opened, devicectl stays attached to it and its output goes to a file; when the
/// person says it stopped or does not work, the last of it goes with the request.
public enum DeviceConsoleLog {
    nonisolated(unsafe) private static var attached: Process?

    /// One file per project folder.
    public static func url(projectRoot: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness/DeviceLogs/\((projectRoot as NSString).lastPathComponent).log")
    }

    /// Opens the app again attached to its output (`--console`). The app restarts once; the earlier attachment ends.
    public static func attach(xcrunURL: URL, projectRoot: String, deviceIdentifier: String, bundleIdentifier: String,
                               environment: [String: String]) {
        attached?.terminate()
        let file = url(projectRoot: projectRoot)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data("[\(Date())] 開きました\n".utf8))
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        handle.seekToEndOfFile()
        let process = Process()
        process.executableURL = xcrunURL
        process.arguments = ["devicectl", "device", "process", "launch", "--console", "--terminate-existing",
                             "--device", deviceIdentifier, bundleIdentifier]
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { _ in try? handle.close() }
        do { try process.run(); attached = process } catch { try? handle.close() }
    }

    /// The last lines worth reading: what the app printed, without devicectl's own lines or a model library's loading
    /// chatter (2026-11-13: the 40 lines sent with 「全く何にも聞こえない」 were all llama.cpp's tensor list); at most `limit`.
    /// When the app had closed, a line says so: what happened after the person opened it again is not in the file.
    public static func tail(projectRoot: String, limit: Int = 40) -> [String] {
        guard let data = try? Data(contentsOf: url(projectRoot: projectRoot)) else { return [] }
        let all = String(decoding: data.suffix(400_000), as: UTF8.self).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let closed = all.last?.hasPrefix("The app terminated") == true
        var lines = Array(all.filter { !isNoise($0) }.suffix(limit))
        if closed { lines.append(closedNote) }
        return lines
    }

    /// Said when the file ends with the app closing.
    public static let closedNote = "(アプリはここで閉じています。このあと iPhone で開き直したときの様子は、この記録にはありません)"

    static func isNoise(_ line: String) -> Bool {
        let own = ["Launched application", "Waiting for the application", "Press Control-C", "The app terminated"]
        let library = ["llama_", "llama:", "ggml_", "gguf_", "load_tensors", "load:", "print_info", "create_tensor", "sched_", "graph_",
                       "llm_load", "common_", "init_tokenizer", "init:", "set_abort", "Metal", "MTL", "'"]
        return own.contains { line.hasPrefix($0) } || library.contains { line.hasPrefix($0) }
            || line.range(of: #"^[\w.]+:\s+(n_|f_|model|file|type|vocab|arch|general|token|BOS|EOS|EOT|PAD|LF)"#, options: .regularExpression) != nil
    }
}
