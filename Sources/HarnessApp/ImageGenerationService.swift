import AppKit
import Foundation
import HarnessCore

/// Runs a local image model (2026-10-09; mflux on Apple silicon) from the command in the purpose-model catalog. Before it
/// runs, the language models are moved out of memory: the Backburner server this App started is stopped (it starts again
/// on the next use) and Ollama is asked to unload its models. A Backburner the user launched in Terminal is left alone.
protocol ImageGenerating: Sendable {
    func generate(option: PurposeModelOption, prompt: String, output: URL, options: ImageGenerationOptions) async throws
}

/// What a run may be told besides the prompt. `seconds` and `image` reach only commands with {seconds} and {image}.
struct ImageGenerationOptions: Sendable {
    var seed: Int
    var seconds: Int?
    var image: URL?
    /// A voice the video keeps and moves the mouth to; reaches only commands with {audio}.
    var audio: URL? = nil
    /// A long video's scene plan (JSON); reaches only commands with {plan}.
    var plan: URL? = nil
    /// More pictures for a video (2026-11-10, the user: 「複数の画像を読み込ませてそれを元に動画に」): keyframes spread over the
    /// clip after the first; reach only commands with {keyframes}, which becomes one argument per picture.
    var keyframes: [URL] = []
    /// The conversation's first face, which results are compared with and put back to; reaches only commands with {face}.
    var face: URL? = nil
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

    func generate(option: PurposeModelOption, prompt: String, output: URL, options: ImageGenerationOptions) async throws {
        guard let template = option.command, let tool = template.first else { throw Failure.noCommand }
        // {home} in the program's own path too (2026-11-07: a video model's Python was looked up as 「{home}/Tools/…」 and never ran).
        let program = tool.replacingOccurrences(of: "{home}", with: FileManager.default.homeDirectoryForCurrentUser.path)
        guard let executable = Self.resolve(program) else { throw Failure.notInstalled(program) }
        // "No model" under a lease for the whole run: running language requests finish first, and a chat request that comes
        // in meanwhile waits instead of loading the 27B beside the image model.
        let log = try await ModelRuntimes.shared.withLease(.none) {
            try Task.checkCancellation()
            await Self.releaseLanguageModels()
            let arguments = Self.arguments(template.dropFirst(), prompt: prompt, output: output, seed: options.seed, seconds: options.seconds, image: options.image, audio: options.audio, plan: options.plan, keyframes: options.keyframes, face: options.face)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try await Self.run(executable, arguments, limit: option.timeLimit ?? (1200 + Double(options.seconds ?? 0) * 150))
        }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw log.isEmpty ? Failure.noImage : Failure.failed(String(log.suffix(300)))
        }
    }

    static func arguments(_ template: ArraySlice<String>, prompt: String, output: URL, seed: Int = Int.random(in: 1...999_999),
                          seconds: Int? = nil, image: URL? = nil, audio: URL? = nil, plan: URL? = nil, keyframes: [URL] = [], face: URL? = nil) -> [String] {
        // A flag whose value was not given goes with it: ["--image", "{image}"] without an image is left out.
        var kept: [String] = []
        for argument in template {
            if (argument.contains("{image}") && image == nil) || (argument.contains("{seconds}") && seconds == nil)
                || (argument.contains("{audio}") && audio == nil) || (argument.contains("{plan}") && plan == nil)
                || (argument == "{keyframes}" && keyframes.isEmpty) || (argument.contains("{face}") && face == nil) { _ = kept.popLast(); continue }
            if argument == "{keyframes}" { kept += keyframes.map(\.path); continue }
            kept.append(argument)
        }
        return kept.map {
            $0.replacingOccurrences(of: "{prompt}", with: prompt).replacingOccurrences(of: "{output}", with: output.path)
                .replacingOccurrences(of: "{seed}", with: String(seed))
                .replacingOccurrences(of: "{seconds}", with: seconds.map(String.init) ?? "")
                .replacingOccurrences(of: "{image}", with: image?.path ?? "")
                .replacingOccurrences(of: "{audio}", with: audio?.path ?? "")
                .replacingOccurrences(of: "{plan}", with: plan?.path ?? "")
                .replacingOccurrences(of: "{face}", with: face?.path ?? "")
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

    /// Runs the tool with a time limit (20 minutes, more for a long video); returns its combined output. Cancelling the
    /// task stops the tool (the card's 止める).
    static func run(_ executable: URL, _ arguments: [String], limit: Double = 1200) async throws -> String {
        let running = RunningProcess()
        return try await withTaskCancellationHandler {
            try await launch(executable, arguments, limit: limit, running: running)
        } onCancel: { running.stopIfRunning() }
    }

    private static func launch(_ executable: URL, _ arguments: [String], limit: Double, running: RunningProcess) async throws -> String {
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
            running.attach(process)
            process.terminationHandler = { _ in
                running.finished()
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: collected.text)
            }
            do {
                try process.run()
                if Task.isCancelled { running.stopIfRunning() }
                // Said in the log when it is the limit that stops it (2026-11-08: a run stopped at 20 minutes showed only
                // its last lines, as if it had failed).
                DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                    if running.isRunning { collected.append(Data("\n時間の上限(\(Int(limit / 60)) 分)を超えたので止めました。".utf8)) }
                    running.stopIfRunning()
                }
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

/// The time limit or the user's 止める: the tool is stopped if it is still running then.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var quitting: (any NSObjectProtocol)?
    /// Quitting the app stops the tool too: otherwise it keeps the memory and its result reaches no card.
    func attach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.stopIfRunning()
        }
    }
    func finished() {
        lock.lock(); defer { lock.unlock() }
        if let quitting { NotificationCenter.default.removeObserver(quitting) }
        quitting = nil
    }
    func stopIfRunning() {
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning == true { process?.terminate() }
    }
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true
    }
}
