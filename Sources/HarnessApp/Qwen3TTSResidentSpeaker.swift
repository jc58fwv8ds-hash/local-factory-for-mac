import Foundation
import HarnessCore

/// The resident speaker (2026-10-19, roadmap V2): `qwen3_tts_server.py` keeps the model loaded, so a sentence starts to
/// sound about 1.4 s after it is asked for (1.7B on the M5) instead of the 7 s a fresh process needs every time. Each
/// request gets its own private folder (0700) holding the reference voice and the pieces; the folder is removed once
/// the request ends. One request at a time; the process stops with `stop()` or when the app quits.
actor Qwen3TTSResidentSpeaker {
    enum Failure: LocalizedError, Equatable {
        case notInstalled, startFailed, generationFailed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "音声エンジンが入っていません。設定の「音声」から導入してください"
            case .startFailed: "音声エンジンを起動できませんでした"
            case .generationFailed(let reason): "読み上げを作れませんでした(\(reason))"
            }
        }
    }

    private let configuration: Qwen3TTSMLXConfiguration
    private var process: Process?
    private var input: FileHandle?
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator?

    init(configuration: Qwen3TTSMLXConfiguration = .managed()) {
        self.configuration = configuration
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Starts the process and waits until the model is loaded (at most 90 s).
    func start() async throws {
        if isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: configuration.pythonExecutableURL.path),
              FileManager.default.fileExists(atPath: configuration.serverURL.path) else { throw Failure.notInstalled }
        let process = Process(), toServer = Pipe(), fromServer = Pipe()
        process.executableURL = configuration.pythonExecutableURL
        process.arguments = ["-I", configuration.serverURL.path, "--model", configuration.modelURL.path]
        process.environment = ["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "PYTHONUNBUFFERED": "1",
                               "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.startFailed }
        self.process = process
        input = toServer.fileHandleForWriting
        lines = fromServer.fileHandleForReading.bytes.lines.makeAsyncIterator()
        let ready = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await self.nextLine()?.contains("\"ready\"") == true }
            group.addTask { try await Task.sleep(for: .seconds(90)); return false }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard ready else { stop(); throw Failure.startFailed }
    }

    /// Speaks one text in the reference voice; each finished piece is returned (WAV data) as soon as it exists.
    func speak(_ text: String, referenceAudio: Data, referenceText: String, languageCode: String) async throws -> [Data] {
        var pieces: [Data] = []
        try await speak(text, referenceAudio: referenceAudio, referenceText: referenceText, languageCode: languageCode) {
            pieces.append($0)
        }
        return pieces
    }

    func speak(_ text: String, referenceAudio: Data, referenceText: String, languageCode: String,
               onPiece: (Data) async -> Void) async throws {
        try await start()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessSpeaker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let reference = folder.appendingPathComponent("reference.wav")
        try referenceAudio.write(to: reference, options: .atomic)
        let id = UUID().uuidString
        let request: [String: String] = ["id": id, "folder": folder.path, "text": text, "referenceText": referenceText,
                                         "referenceAudioPath": reference.path,
                                         "language": languageCode.lowercased().hasPrefix("ja") ? "Japanese" : "Auto"]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        try input?.write(contentsOf: line)
        while let reply = try await nextLine() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
                  object["id"] as? String == id else { continue }
            if let path = object["path"] as? String {
                // Only pieces inside this request's folder are read.
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard url.path.hasPrefix(folder.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: url) else {
                    throw Failure.generationFailed("出力の場所が不正です")
                }
                await onPiece(data)
            } else if object["status"] as? String == "done" {
                return
            } else if object["status"] as? String == "failed" {
                throw Failure.generationFailed(object["reason"] as? String ?? "不明")
            }
        }
        stop()
        throw Failure.generationFailed("音声エンジンが止まりました")
    }

    func stop() {
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        lines = nil
    }

    /// One request at a time reads the server's lines, so the iterator is taken out, advanced and put back.
    private func nextLine() async throws -> String? {
        var iterator = lines
        let line = try await iterator?.next()
        lines = iterator
        return line
    }
}
