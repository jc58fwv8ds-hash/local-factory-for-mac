import Foundation
import HarnessCore

enum ModelAcquisitionChecks {
    static func run() async throws {
        let entry = try require(ModelCatalogEntry.recommended.first)
        let request = try require(
            ModelAcquisitionRequest(entry: entry, runtime: .ollama)
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let resumedAt = Date(timeIntervalSince1970: 2_000)
        var checkpoint: ModelAcquisitionCheckpoint?

        ModelAcquisitionCheckpointWorkflow.started(
            request,
            in: &checkpoint,
            now: startedAt
        )
        ModelAcquisitionCheckpointWorkflow.started(
            request,
            in: &checkpoint,
            now: resumedAt
        )
        try expect(
            checkpoint == ModelAcquisitionCheckpoint(
                request: request,
                startedAt: startedAt,
                updatedAt: resumedAt
            ),
            "Resuming model acquisition did not preserve its original start time"
        )

        let library = ProjectLibrary(
            records: [ProjectRecord(project: .starter)],
            modelAcquisitionCheckpoint: checkpoint
        )
        let encoded = try JSONEncoder().encode(library)
        let json = String(decoding: encoded, as: UTF8.self)
        try expect(
            !json.contains("commandOutput")
                && !json.contains("temporaryDirectory")
                && !json.contains("downloadedBytes"),
            "Model acquisition persistence leaked process output or partial data"
        )
        let decoded = try JSONDecoder().decode(ProjectLibrary.self, from: encoded)
        try expect(
            decoded.modelAcquisitionCheckpoint == checkpoint,
            "Model acquisition checkpoint did not survive workspace encoding"
        )

        ModelAcquisitionCheckpointWorkflow.completed(request, in: &checkpoint)
        try expect(
            checkpoint == nil,
            "Completed model acquisition did not clear its checkpoint"
        )
        ModelAcquisitionCheckpointWorkflow.started(request, in: &checkpoint)
        ModelAcquisitionCheckpointWorkflow.discarded(in: &checkpoint)
        try expect(
            checkpoint == nil,
            "Discarding model acquisition did not clear its checkpoint"
        )

        let legacyLibrary = ProjectLibrary(records: [ProjectRecord(project: .starter)])
        let legacyData = try JSONEncoder().encode(legacyLibrary)
        let legacyJSON = String(decoding: legacyData, as: UTF8.self)
        try expect(
            !legacyJSON.contains("modelAcquisitionCheckpoint"),
            "Empty model acquisition state should not alter legacy workspace JSON"
        )
        let decodedLegacy = try JSONDecoder().decode(ProjectLibrary.self, from: legacyData)
        try expect(
            decodedLegacy.modelAcquisitionCheckpoint == nil,
            "Legacy workspace JSON did not default model acquisition state to nil"
        )

        try checkProgressParsing()
        try checkCatalogRefreshAndSafeErrors()
        try await checkProcessCancellation(request: request)

        print("✓ Interrupted model acquisition resumes without storing logs or partial model data")
    }

    private static func checkCatalogRefreshAndSafeErrors() throws {
        let currentEntry = try require(
            ModelCatalogEntry.recommended.first { $0.id == "qwen-3.8-27b-q4" }
        )
        try expect(
            currentEntry.lmStudioIdentifier
                == "https://huggingface.co/lmstudio-community/Qwen3.8-27B-GGUF@Q4_K_M",
            "Qwen 3.8 must use the explicit Hugging Face URL accepted by LM Studio"
        )
        let legacyEntry = ModelCatalogEntry(
            id: currentEntry.id,
            displayName: currentEntry.displayName,
            summary: currentEntry.summary,
            parameterLabel: currentEntry.parameterLabel,
            estimatedSizeGB: currentEntry.estimatedSizeGB,
            isRecommended: true,
            ollamaIdentifier: currentEntry.ollamaIdentifier,
            lmStudioIdentifier: "lmstudio-community/Qwen3.8-27B-GGUF@Q4_K_M"
        )
        let legacyRequest = try require(
            ModelAcquisitionRequest(entry: legacyEntry, runtime: .lmStudio)
        )
        let checkpoint = ModelAcquisitionCheckpoint(
            request: legacyRequest,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let refreshed = ModelAcquisitionCheckpointWorkflow.refreshed(
            checkpoint,
            catalog: ModelCatalogEntry.recommended
        )
        try expect(
            refreshed?.request.modelIdentifier == currentEntry.lmStudioIdentifier
                && refreshed?.startedAt == checkpoint.startedAt,
            "Interrupted model acquisition must migrate to the corrected catalog identifier"
        )

        let raw = "\u{001B}[31mFailed to resolve artifact /private/path: does not exist\u{001B}[0m"
        let message = ModelCommandFailureExplainer.installationMessage(
            from: raw,
            runtime: .lmStudio
        )
        try expect(
            message.contains("配布元")
                && !message.contains("\u{001B}")
                && !message.contains("/private/path"),
            "Model command failures must become bounded guidance without raw logs or paths"
        )
    }

    private static func checkProgressParsing() throws {
        let ollama = try require(
            ModelAcquisitionProgressParser.parse(
                "\u{001B}[Kpulling 7d3f: 42% ▕████▏ 7.1 GB/16.8 GB"
            )
        )
        try expect(
            ollama.fraction == 0.42
                && ollama.status.contains("ダウンロード"),
            "Ollama progress output did not become a bounded progress event"
        )
        let liveOllamaChunk = try require(
            ModelAcquisitionProgressParser.parse(
                "pulling e000: 24% 4.0 GB/16 GB\npulling manifest"
            )
        )
        try expect(
            liveOllamaChunk.fraction == 0.24
                && liveOllamaChunk.status.contains("ダウンロード"),
            "Live Ollama chunks must prefer byte progress over repeated manifest output"
        )
        let lmStudio = try require(
            ModelAcquisitionProgressParser.parse("Downloading model 67.5%")
        )
        try expect(
            lmStudio.fraction == 0.675,
            "LM Studio progress output lost its fractional percentage"
        )
        let verifying = try require(
            ModelAcquisitionProgressParser.parse("verifying sha256 digest")
        )
        try expect(
            verifying.fraction == nil && verifying.status.contains("検証"),
            "Verification output did not become a safe phase event"
        )
        try expect(
            ModelAcquisitionProgressParser.parse("unrelated private log") == nil,
            "Unknown model command output should not reach the UI"
        )
    }

    private static func checkProcessCancellation(
        request: ModelAcquisitionRequest
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessModelCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-ollama")
        try Data(
            "#!/bin/sh\nprintf 'pulling model: 42%%\\n'\nexec /bin/sleep 30\n".utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )
        let service = LocalModelService(
            runtimes: [
                RuntimeCandidate(
                    kind: .ollama,
                    executablePath: executable.path,
                    isInstalled: true
                )
            ]
        )
        let recorder = ModelProgressRecorder()
        let installation = Task {
            try await service.install(request) { progress in
                await recorder.append(progress)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var observedProgress = await recorder.latest
        while observedProgress?.fraction != 0.42 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            observedProgress = await recorder.latest
        }
        try expect(
            observedProgress?.fraction == 0.42,
            "Live model command output did not reach its progress observer"
        )
        installation.cancel()

        do {
            try await installation.value
            throw CheckFailure(
                description: "Cancelling model acquisition did not stop its process"
            )
        } catch is CancellationError {
            // Expected: the cancellable command runner terminated the child process.
        }
    }
}

private actor ModelProgressRecorder {
    private var values: [ModelAcquisitionProgress] = []

    var latest: ModelAcquisitionProgress? { values.last }

    func append(_ progress: ModelAcquisitionProgress) {
        values.append(progress)
    }
}
