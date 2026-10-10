@preconcurrency import AVFAudio
import Foundation
import HarnessCore

struct VoiceSynthesisAudio: Equatable, Sendable {
    let wavData: Data
    let sampleRate: Double
    let durationMilliseconds: Int
}

enum VoiceEngineAdapterError: LocalizedError, Equatable {
    case policy(VoiceEngineSynthesisPolicyError)
    case generationFailed
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .policy(let error): error.localizedDescription
        case .generationFailed: "ローカル音声の生成に失敗しました。Apple音声で返答を表示します。"
        case .invalidOutput: "生成された音声を安全に確認できませんでした。"
        }
    }
}

protocol VoiceEngineAdapting: Sendable {
    func readiness() async -> VoiceEngineReadiness
    func synthesize(text: String, input: VoiceCapsuleEngineInput) async throws
        -> VoiceSynthesisAudio
}

protocol VoiceEngineCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> Int32
}

actor BoundedVoiceEngineCommandRunner: VoiceEngineCommandRunning {
    private let runner = BoundedCommandRunner(
        timeout: .seconds(180),
        maximumOutputBytes: 8_000
    )

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> Int32 {
        try await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        ).exitCode
    }
}

actor Qwen3TTSMLXAdapter: VoiceEngineAdapting {
    private let configuration: Qwen3TTSMLXConfiguration
    private let commandRunner: any VoiceEngineCommandRunning
    private let fileManager: FileManager

    init(
        configuration: Qwen3TTSMLXConfiguration = .managed(),
        commandRunner: any VoiceEngineCommandRunning = BoundedVoiceEngineCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    func readiness() -> VoiceEngineReadiness {
        let engineID = VoiceEngineCatalog.qwen3TTSMLX.id
        #if !arch(arm64)
        return VoiceEngineReadiness(
            engineIdentifier: engineID,
            phase: .unsupportedHardware
        )
        #else
        guard fileManager.fileExists(atPath: configuration.activeURL.path) else {
            return VoiceEngineReadiness(engineIdentifier: engineID, phase: .notInstalled)
        }
        guard fileManager.isExecutableFile(
            atPath: configuration.pythonExecutableURL.path
        ), isRegularFile(configuration.workerURL) else {
            return VoiceEngineReadiness(engineIdentifier: engineID, phase: .runtimeMissing)
        }
        let config = configuration.modelURL.appendingPathComponent("config.json")
        let singleWeights = configuration.modelURL.appendingPathComponent("model.safetensors")
        let weightIndex = configuration.modelURL
            .appendingPathComponent("model.safetensors.index.json")
        guard isRegularFile(config),
              isRegularFile(singleWeights) || isRegularFile(weightIndex) else {
            return VoiceEngineReadiness(engineIdentifier: engineID, phase: .modelMissing)
        }
        guard let receiptData = try? Data(contentsOf: configuration.receiptURL),
              let receipt = try? JSONDecoder().decode(
                VoiceEngineInstallationReceipt.self,
                from: receiptData
              ),
              receipt.schemaVersion == 1,
              receipt.engineIdentifier == engineID,
              receipt.runtimeVersion == VoiceEngineCatalog.qwen3TTSMLXRuntimeVersion,
              receipt.modelIdentifier == VoiceEngineCatalog.qwen3TTSMLX.modelIdentifier,
              receipt.modelRevision == VoiceEngineCatalog.qwen3TTSMLXModelRevision else {
            return VoiceEngineReadiness(engineIdentifier: engineID, phase: .failed)
        }
        return VoiceEngineReadiness(engineIdentifier: engineID, phase: .ready)
        #endif
    }

    func synthesize(
        text: String,
        input: VoiceCapsuleEngineInput
    ) async throws -> VoiceSynthesisAudio {
        let currentReadiness = readiness()
        let request = VoiceEngineSynthesisRequest(
            text: text,
            languageCode: input.manifest.styleProfile.languageCode,
            capsuleID: input.manifest.id,
            capsuleRevisionHash: input.capsuleRevisionHash,
            hasReferenceTranscript: input.referenceTranscript != nil
        )
        if let error = VoiceEngineSynthesisPolicy.validationError(
            for: request,
            manifest: input.manifest,
            readiness: currentReadiness
        ) {
            throw VoiceEngineAdapterError.policy(error)
        }

        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "HarnessVoiceEngine-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try setPermissions(0o700, at: directory)
        defer { try? fileManager.removeItem(at: directory) }

        let textURL = directory.appendingPathComponent("speech.txt")
        let audioURL = directory.appendingPathComponent("reference.wav")
        let transcriptURL = directory.appendingPathComponent("reference.txt")
        let outputURL = directory.appendingPathComponent("output.wav")
        let requestURL = directory.appendingPathComponent("request.json")
        try Data(text.utf8).write(to: textURL, options: .atomic)
        try input.referenceAudio.write(to: audioURL, options: .atomic)
        guard let transcript = input.referenceTranscript else {
            throw VoiceEngineAdapterError.policy(.referenceTranscriptRequired)
        }
        try Data(transcript.utf8).write(to: transcriptURL, options: .atomic)
        let payload = WorkerRequest(
            modelPath: configuration.modelURL.path,
            textPath: textURL.path,
            referenceAudioPath: audioURL.path,
            referenceTextPath: transcriptURL.path,
            outputPath: outputURL.path,
            language: languageName(for: request.languageCode)
        )
        try JSONEncoder().encode(payload).write(to: requestURL, options: .atomic)
        for url in [textURL, audioURL, transcriptURL, requestURL] {
            try setPermissions(0o600, at: url)
        }
        let status = try await commandRunner.run(
            executableURL: configuration.pythonExecutableURL,
            arguments: [configuration.workerURL.path, "--request", requestURL.path],
            environment: [
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
                "PYTHONUNBUFFERED": "1"
            ]
        )
        guard status == 0 else { throw VoiceEngineAdapterError.generationFailed }
        return try validatedAudio(at: outputURL)
    }

    private func validatedAudio(at url: URL) throws -> VoiceSynthesisAudio {
        guard isRegularFile(url),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 44, size <= 100_000_000,
              let file = try? AVAudioFile(forReading: url) else {
            throw VoiceEngineAdapterError.invalidOutput
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate >= 8_000, sampleRate <= 96_000, file.length > 0 else {
            throw VoiceEngineAdapterError.invalidOutput
        }
        let duration = Int((Double(file.length) / sampleRate * 1_000).rounded())
        guard duration > 0, duration <= 300_000,
              let data = try? Data(contentsOf: url) else {
            throw VoiceEngineAdapterError.invalidOutput
        }
        return VoiceSynthesisAudio(
            wavData: data,
            sampleRate: sampleRate,
            durationMilliseconds: duration
        )
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func languageName(for code: String) -> String {
        code.lowercased().hasPrefix("ja") ? "Japanese" : "Auto"
    }
}

private struct WorkerRequest: Encodable {
    let schemaVersion = 1
    let engineIdentifier = VoiceEngineCatalog.qwen3TTSMLX.id
    let modelPath: String
    let textPath: String
    let referenceAudioPath: String
    let referenceTextPath: String
    let outputPath: String
    let language: String
}
