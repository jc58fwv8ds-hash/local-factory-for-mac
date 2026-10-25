import Foundation
import HarnessCore

/// Runs a local image model (2026-10-09; mflux on Apple silicon) from the command in the purpose-model catalog. Before it
/// runs, the language models are moved out of memory: the Backburner server this App started is stopped (it starts again
/// on the next use) and Ollama is asked to unload its models. A Backburner the user launched in Terminal is left alone.
protocol ImageGenerating: Sendable {
    func generate(option: PurposeModelOption, prompt: String, output: URL) async throws
}

struct ImageGenerationService: ImageGenerating {
    enum Failure: LocalizedError {
        case noCommand, notInstalled(String), failed(String), noImage
        var errorDescription: String? {
            switch self {
            case .noCommand: "この画像モデルには実行方法が設定されていません(purpose-models.json の command)。"
            case .notInstalled(let tool): "画像を作るプログラム「\(tool)」が見つかりません。導入してからもう一度試してください。"
            case .failed(let log): "画像を作れませんでした。記録の最後: \(log)"
            case .noImage: "画像のファイルができませんでした。"
            }
        }
    }

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin",
                              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
                              "/usr/bin", "/bin"]

    func generate(option: PurposeModelOption, prompt: String, output: URL) async throws {
        guard let template = option.command, let tool = template.first else { throw Failure.noCommand }
        guard let executable = Self.resolve(tool) else { throw Failure.notInstalled(tool) }
        // "No model" under a lease for the whole run: running language requests finish first, and a chat request that comes
        // in meanwhile waits instead of loading the 27B beside the image model.
        let log = try await ModelRuntimes.shared.withLease(.none) {
            await Self.releaseLanguageModels()
            let arguments = Self.arguments(template.dropFirst(), prompt: prompt, output: output)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try await Self.run(executable, arguments)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw log.isEmpty ? Failure.noImage : Failure.failed(String(log.suffix(300)))
        }
    }

    static func arguments(_ template: ArraySlice<String>, prompt: String, output: URL, seed: Int = Int.random(in: 1...999_999)) -> [String] {
        template.map {
            $0.replacingOccurrences(of: "{prompt}", with: prompt).replacingOccurrences(of: "{output}", with: output.path)
                .replacingOccurrences(of: "{seed}", with: String(seed))
                .replacingOccurrences(of: "{width}", with: "1024").replacingOccurrences(of: "{height}", with: "1024")
                .replacingOccurrences(of: "{home}", with: FileManager.default.homeDirectoryForCurrentUser.path)
        }
    }

    static func resolve(_ tool: String) -> URL? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? URL(fileURLWithPath: tool) : nil }
        return searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Frees GPU memory for the image model: unloads every model Ollama holds (Backburner and Strata are stopped by the
    /// coordinator's "no model" lease the caller holds).
    static func releaseLanguageModels() async {
        guard let ps = URL(string: "http://127.0.0.1:11434/api/ps"),
              let (data, _) = try? await URLSession.shared.data(from: ps),
              let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] else { return }
        for name in models.compactMap({ $0["name"] as? String }) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "keep_alive": 0])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Runs the tool with a 20-minute limit; returns its combined output.
    static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPaths.joined(separator: ":")
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // Progress bars can fill the pipe: read while it runs, keep the last 8 KB.
            let collected = OutputTail()
            pipe.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
            let running = RunningProcess(process)
            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: collected.text)
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1200) { running.stopIfRunning() }
            } catch {
                continuation.resume(throwing: Failure.failed(error.localizedDescription))
            }
        }
    }
}

private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(more)
        if data.count > 8_192 { data = data.suffix(8_192) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// The 20-minute limit: the tool is stopped if it is still running then.
private final class RunningProcess: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func stopIfRunning() { if process.isRunning { process.terminate() } }
}
