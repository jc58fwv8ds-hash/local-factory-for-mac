import Foundation
import HarnessCore

/// Starts the locally installed Strata server (`~/Strata/serve/server.py`, 127.0.0.1:8090) for the 125B MoE writing option
/// (2026-10-25) and stops it again. It and the 27B (Backburner) do not fit in memory together, so starting one stops the
/// other; a server the user started in Terminal is never stopped, and Strata is then refused with a message instead.
/// Measured on the M5 32 GB: 15-17 tokens/s written, 20 of 30 C2/C3 tasks (the 27B: 19-24).
actor StrataServer {
    static let shared = StrataServer()

    enum Failure: LocalizedError {
        case notInstalled(String), backburnerBusy, didNotStart(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled(let path): "Strata の設定が見つかりません(\(path))。"
            case .backburnerBusy: "27B のサーバー(Backburner)が別に起動されているため、125B を動かすメモリがありません。ターミナルで起動した Backburner を止めてください。"
            case .didNotStart(let log): "Strata を起動できませんでした。記録: \(log)"
            }
        }
    }

    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Strata")
    private let models = URL(string: "http://127.0.0.1:8090/v1/models")!
    private var process: Process?
    private var starting: Task<Void, Error>?

    var log: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness/strata-server.log")
    }

    /// "strata:<config>" ({home} = the home folder) -> the config file.
    static func configPath(from identifier: String) -> String? {
        guard identifier.hasPrefix(LocalInferenceService.strataPrefix) else { return nil }
        return String(identifier.dropFirst(LocalInferenceService.strataPrefix.count))
            .replacingOccurrences(of: "{home}", with: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func ensureRunning(config: String) async throws {
        // Only a server this App started counts: another program answering on 8090 is not known to serve this config.
        if process?.isRunning == true, await isReady() { return }
        if let starting { return try await starting.value }
        let task = Task { try await start(config: config) }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Stops only a server this App started, with the processes it started (the engine and the image reader): server.py
    /// leaves them running when it is stopped. They are found as its descendants, not by name, so a Strata the user runs
    /// elsewhere is never touched.
    func stop() {
        guard let process else { return }
        let children = Self.descendants(of: process.processIdentifier)
        process.terminate()
        process.waitUntilExit()
        self.process = nil
        for pid in children { kill(pid, SIGTERM) }
        for _ in 0..<50 where children.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
        for pid in children where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Every process below `pid` (children, their children, ...), from `pgrep -P`.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = [], frontier = [pid]
        while let next = frontier.popLast() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", String(next)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            let children = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
            found += children
            frontier += children
        }
        return found
    }

    private func start(config: String) async throws {
        let python = directory.appendingPathComponent(".venv/bin/python").path
        guard FileManager.default.isExecutableFile(atPath: python), FileManager.default.fileExists(atPath: config)
        else { throw Failure.notInstalled(config) }
        // The coordinator has stopped this App's Backburner; one started in Terminal still holds the memory.
        if await BackburnerServer.shared.isAnswering() { throw Failure.backburnerBusy }
        _ = await HelperNode.shared.prepareStrataRows()
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: python)
        server.arguments = [directory.appendingPathComponent("serve/server.py").path, "--engine", "strata", "--config", config, "--port", "8090"]
        server.currentDirectoryURL = directory
        server.standardOutput = output
        server.standardError = output
        try server.run()
        process = server
        // The 37.6 GB model streams its experts from the SSD: ready in about a minute; allow 5.
        for _ in 0..<300 {
            // Its own process first: if another program holds 8090, this server exits and its answers are not ours.
            guard server.isRunning else { break }
            if await isReady() { return }
            try await Task.sleep(for: .seconds(1))
        }
        stop()
        throw Failure.didNotStart(log.path)
    }

    private func isReady() async -> Bool {
        var request = URLRequest(url: models)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
