import Foundation
import HarnessCore

/// Starts the locally installed Backburner server (`~/backburner/scripts/serve.sh`, 127.0.0.1:8080) the first time its model
/// is used and stops it when the App quits, so no Terminal is needed. Raising the GPU wired-memory limit needs administrator
/// rights: only then, macOS shows its own password dialog (osascript `with administrator privileges`); the App never stores
/// or sees the password. If the dialog is cancelled the server still starts with the system default limit.
actor BackburnerServer {
    static let shared = BackburnerServer()

    enum Failure: LocalizedError {
        case notInstalled, didNotStart(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "Backburner が見つかりません(~/backburner)。"
            case .didNotStart(let log): "Backburner を起動できませんでした。記録: \(log)"
            }
        }
    }

    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("backburner")
    private let health = URL(string: "http://127.0.0.1:8080/health")!
    private var process: Process?
    private var starting: Task<Void, Error>?
    /// The GGUF this App's server was started with (nil: serve.sh's default model).
    private var currentModel: String?

    /// A Backburner model identifier "gguf:<path>" names the file to serve ({home} = the home folder); any other
    /// identifier means the default model (2026-10-09: the writing model of 用途ごとのモデル runs 2.4x faster here than
    /// in Ollama, 8.1 vs 3.4 tokens/s for the same IQ3 file).
    static func modelPath(from identifier: String) -> String? {
        guard identifier.hasPrefix("gguf:") else { return nil }
        return String(identifier.dropFirst(5))
            .replacingOccurrences(of: "{home}", with: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    var log: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness/backburner-server.log")
    }

    /// Wired-memory limit (MB) Backburner wants on this Mac, or nil when no change is needed (same rule as its launcher).
    static func wiredLimitToRequest(memoryMB: Int, currentLimitMB: Int) -> Int? {
        let want = memoryMB - 4096
        return memoryMB <= 32768 && currentLimitMB < want ? want : nil
    }

    func ensureRunning(model: String? = nil) async throws {
        if await isHealthy() {
            // A server the user started is used as it is; this App's own server is restarted for another model.
            if process == nil || model == currentModel { return }
            stop()
            for _ in 0..<30 where await isHealthy() { try await Task.sleep(for: .seconds(1)) }
        }
        if let starting { return try await starting.value }
        let task = Task { try await start(model: model) }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    /// Stops only a server this App started; a server the user launched in Terminal is left alone.
    func stop() {
        process?.terminate()
        process = nil
        currentModel = nil
    }

    private func start(model: String?) async throws {
        let serve = directory.appendingPathComponent("scripts/serve.sh")
        guard FileManager.default.isExecutableFile(atPath: serve.path) else { throw Failure.notInstalled }
        raiseWiredLimitIfNeeded()
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/bin/bash")
        server.arguments = [serve.path]
        server.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        let venv = directory.appendingPathComponent(".venv/bin").path
        environment["PATH"] = venv + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PY"] = venv + "/python3"
        if let model {
            // Another GGUF than the default 27B: the DFlash drafter is trained for that 27B and slows a fine-tune down
            // (a 27B fine-tune: 8.1 tokens/s with it, 10.4 without, measured 2026-10-10), so it runs without speculation.
            environment["MODEL"] = model
            environment["DRAFT"] = ""
            environment["SPEC_TYPE"] = "none"
        }
        server.environment = environment
        server.standardOutput = output
        server.standardError = output
        try server.run()
        process = server
        currentModel = model
        // Model load takes ~25 s on a warm SSD; allow up to 4 minutes.
        for _ in 0..<240 {
            if await isHealthy() { return }
            guard server.isRunning else { break }
            try await Task.sleep(for: .seconds(1))
        }
        stop()
        throw Failure.didNotStart(log.path)
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: health)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func raiseWiredLimitIfNeeded() {
        let memoryMB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        guard let current = Int(Self.run("/usr/sbin/sysctl", ["-n", "iogpu.wired_limit_mb"]).trimmingCharacters(in: .whitespacesAndNewlines)),
              let want = Self.wiredLimitToRequest(memoryMB: memoryMB, currentLimitMB: current) else { return }
        let script = "do shell script \"/usr/sbin/sysctl iogpu.wired_limit_mb=\(want)\" with administrator privileges "
            + "with prompt \"Backburner がモデルを GPU メモリに保持できるように設定します(再起動まで有効)。\""
        _ = Self.run("/usr/bin/osascript", ["-e", script])
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// Starts Backburner before any request to its runtime; every other runtime passes straight through.
struct BackburnerAwareInferenceProvider: ModelInferenceProvider {
    let base: any ModelInferenceProvider

    func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
        guard request.runtime == .backburner else { return await base.events(for: request) }
        do {
            try await BackburnerServer.shared.ensureRunning(model: BackburnerServer.modelPath(from: request.modelIdentifier))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return await base.events(for: request)
    }
}

/// The App's own model calls (conversation, rename, analysis, documents, images' prompt) are appended per day to
/// ~/Library/Application Support/Harness/model-calls/YYYY-MM-DD.jsonl (backlog #41); files older than 14 days are removed.
struct LoggingInferenceProvider: ModelInferenceProvider {
    let base: any ModelInferenceProvider

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness/model-calls", isDirectory: true)
    }

    func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
        let upstream = await base.events(for: request)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let file = Self.folder.appendingPathComponent(formatter.string(from: Date()) + ".jsonl")
        let started = Date()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var text = ""
                do {
                    for try await piece in upstream { text += piece; continuation.yield(piece) }
                    ModelCallLog.record(request, response: text, error: nil, seconds: Date().timeIntervalSince(started), to: file)
                    continuation.finish()
                } catch {
                    ModelCallLog.record(request, response: text.isEmpty ? nil : text, error: error,
                                        seconds: Date().timeIntervalSince(started), to: file)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
