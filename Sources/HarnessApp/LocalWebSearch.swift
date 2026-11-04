import Foundation

/// Web search on this Mac (2026-11-02, the agent screen): RustXNG (github.com/sahenjp/RustXNG, AGPL-3.0, a separate program,
/// not part of this app) listens on 127.0.0.1:29483 only, needs no API key, and returns the top pages' text with the
/// results. It is started here when it is installed and not running.
struct LocalWebSearch: Sendable {
    static let port = 29483
    static let binary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Tools/rustxng-v0.26.0/rustxng")
    static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LocalFactory-RustXNG.log")
    }

    enum Failure: LocalizedError {
        case notInstalled, notAnswering
        var errorDescription: String? {
            switch self {
            case .notInstalled: "手元の検索(RustXNG)が入っていません"
            case .notAnswering: "手元の検索(RustXNG)が起動しません"
            }
        }
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    /// The results as notes for the model: title, URL, snippet, and the start of the top pages' text.
    func search(_ query: String) async throws -> String {
        try await ensureRunning()
        var components = URLComponents(string: "http://127.0.0.1:\(Self.port)/search")!
        components.queryItems = [.init(name: "q", value: query), .init(name: "format", value: "json"),
                                 .init(name: "max_results", value: "5"), .init(name: "include_raw_content", value: "1")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 60
        let (data, _) = try await URLSession.shared.data(for: request)
        let results = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return Self.notes(results)
    }

    /// Kept short (2026-11-04): five results with three pages came to about 4,000 characters, which the 27B read for 30 s.
    static func notes(_ results: [[String: Any]], pageCharacters: Int = 600) -> String {
        guard !results.isEmpty else { return "(結果なし)" }
        return results.prefix(4).enumerated().map { index, result in
            let title = result["title"] as? String ?? "", url = result["url"] as? String ?? ""
            let snippet = (result["content"] as? String ?? "").prefix(200)
            let page = index < 1 ? (result["raw_content"] as? String ?? "").prefix(pageCharacters) : ""
            return "\(index + 1). \(title)\n\(url)\n\(snippet)" + (page.isEmpty ? "" : "\n本文: \(page)")
        }.joined(separator: "\n\n")
    }

    func ensureRunning() async throws {
        if await isAnswering() { return }
        guard Self.isInstalled else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = ["--bind", "127.0.0.1", "--port", "\(Self.port)"]
        process.environment = ["SEARXNG_PORT": "\(Self.port)", "PATH": "/usr/bin:/bin"]
        FileManager.default.createFile(atPath: Self.log.path, contents: nil)
        let output = try FileHandle(forWritingTo: Self.log)
        process.standardOutput = output
        process.standardError = output
        try process.run()
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(1))
            if await isAnswering() { return }
        }
        throw Failure.notAnswering
    }

    func isAnswering() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/")!)
        request.timeoutInterval = 2
        return ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
    }
}
