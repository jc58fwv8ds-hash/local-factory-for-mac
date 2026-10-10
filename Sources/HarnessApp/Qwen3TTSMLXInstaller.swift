import CryptoKit
import Foundation
import HarnessCore

actor Qwen3TTSMLXInstaller: VoiceEngineInstalling {
    let configuration: Qwen3TTSMLXConfiguration
    let commandRunner: any VoiceEngineInstallationCommandRunning
    let fileManager: FileManager

    init(
        configuration: Qwen3TTSMLXConfiguration = .managed(),
        commandRunner: any VoiceEngineInstallationCommandRunning =
            BoundedVoiceEngineInstallationRunner(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    func preflight() -> VoiceEngineInstallationPreflight {
        let capacity = try? existingStorageURL().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        #if arch(arm64)
        let isAppleSilicon = true
        #else
        let isAppleSilicon = false
        #endif
        return VoiceEngineInstallationPolicy.preflight(
            isAppleSilicon: isAppleSilicon,
            availableDiskBytes: capacity ?? nil
        )
    }

    func hasResumableInstallation() -> Bool {
        fileManager.fileExists(atPath: configuration.stagingURL.path)
    }

    func install(
        onProgress: @escaping @Sendable (VoiceEngineInstallationProgress) async -> Void
    ) async throws {
        let assessment = preflight()
        guard assessment.isHardwareSupported else {
            throw VoiceEngineInstallerError.unsupportedHardware
        }
        guard assessment.canInstall else {
            throw VoiceEngineInstallerError.insufficientStorage
        }
        guard resourcesArePresent() else {
            throw VoiceEngineInstallerError.packagedResourcesMissing
        }
        guard !fileManager.fileExists(atPath: configuration.activeURL.path) else {
            throw VoiceEngineInstallerError.existingInstallation
        }
        try await report(.preparing, "専用領域を準備しています", to: onProgress)
        try prepareStaging()
        try Task.checkCancellation()
        try await prepareBootstrap(onProgress: onProgress)
        try Task.checkCancellation()
        try await prepareRuntime(onProgress: onProgress)
        try Task.checkCancellation()
        try await prepareModel(onProgress: onProgress)
        try Task.checkCancellation()
        try writeFinalReceipt()
        do {
            try fileManager.moveItem(
                at: configuration.stagingURL,
                to: configuration.activeURL
            )
        } catch {
            throw VoiceEngineInstallerError.activationFailed
        }
        try? fileManager.removeItem(at: cacheURL)
        await onProgress(VoiceEngineInstallationProgress(
            phase: .ready,
            fraction: 1,
            status: "検査済みの音声エンジンを有効にしました"
        ))
    }

    func discardPartialInstallation() throws {
        try validateManagedRoot()
        if fileManager.fileExists(atPath: configuration.stagingURL.path) {
            try fileManager.removeItem(at: configuration.stagingURL)
        }
        if fileManager.fileExists(atPath: cacheURL.path) {
            try fileManager.removeItem(at: cacheURL)
        }
        try removeEmptyRootIfPossible()
    }

    func removeInstallation() throws {
        try validateManagedRoot()
        guard fileManager.fileExists(atPath: configuration.rootURL.path) else { return }
        try fileManager.removeItem(at: configuration.rootURL)
    }

    private var cacheURL: URL {
        configuration.rootURL.appendingPathComponent("cache", isDirectory: true)
    }

    private var stagingPythonURL: URL {
        configuration.stagingURL.appendingPathComponent("runtime/bin/python3")
    }

    var stagingModelURL: URL {
        configuration.stagingURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("Qwen3-TTS-12Hz-0.6B-Base-bf16", isDirectory: true)
    }

    var partialReceiptURL: URL {
        configuration.stagingURL.appendingPathComponent("installation-request.json")
    }

    private func prepareStaging() throws {
        try validateManagedRoot()
        try fileManager.createDirectory(
            at: configuration.stagingURL,
            withIntermediateDirectories: true
        )
        try setPermissions(0o700, at: configuration.rootURL)
        try setPermissions(0o700, at: configuration.stagingURL)
        let expected = receipt(installedAt: .distantPast)
        if fileManager.fileExists(atPath: partialReceiptURL.path) {
            guard let data = try? Data(contentsOf: partialReceiptURL),
                  let saved = try? JSONDecoder().decode(
                    VoiceEngineInstallationReceipt.self,
                    from: data
                  ), saved == expected else {
                throw VoiceEngineInstallerError.incompatiblePartialInstallation
            }
        } else {
            try JSONEncoder().encode(expected).write(to: partialReceiptURL, options: .atomic)
            try setPermissions(0o600, at: partialReceiptURL)
        }
    }

    func prepareBootstrap(
        onProgress: @escaping @Sendable (VoiceEngineInstallationProgress) async -> Void
    ) async throws {
        if fileManager.isExecutableFile(atPath: configuration.uvExecutableURL.path) {
            return
        }
        try fileManager.createDirectory(
            at: configuration.bootstrapArchiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        await onProgress(VoiceEngineInstallationProgress(
            phase: .downloadingBootstrap,
            status: "公式セットアップツールを取得して照合しています"
        ))
        if try sha256IfPresent(at: configuration.bootstrapArchiveURL)
            != configuration.uvArchiveSHA256 {
            var status = try await downloadBootstrapArchive(resuming: true)
            if status != 0 {
                try? fileManager.removeItem(at: configuration.bootstrapArchiveURL)
                status = try await downloadBootstrapArchive(resuming: false)
            }
            guard status == 0 else {
                throw VoiceEngineInstallerError.bootstrapDownloadFailed
            }
        }
        guard try sha256(at: configuration.bootstrapArchiveURL)
            == configuration.uvArchiveSHA256 else {
            try? fileManager.removeItem(at: configuration.bootstrapArchiveURL)
            throw VoiceEngineInstallerError.bootstrapIntegrityFailed
        }
        let extractionStatus = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "-xzf", configuration.bootstrapArchiveURL.path,
                "-C", configuration.bootstrapArchiveURL.deletingLastPathComponent().path
            ],
            environment: [:],
            onOutput: nil
        )
        guard extractionStatus == 0,
              fileManager.isExecutableFile(atPath: configuration.uvExecutableURL.path) else {
            throw VoiceEngineInstallerError.bootstrapIntegrityFailed
        }
    }

    private func prepareRuntime(
        onProgress: @escaping @Sendable (VoiceEngineInstallationProgress) async -> Void
    ) async throws {
        await onProgress(VoiceEngineInstallationProgress(
            phase: .installingRuntime,
            status: "専用のPython 3.12と音声実行環境を準備しています"
        ))
        let status = try await commandRunner.run(
            executableURL: configuration.uvExecutableURL,
            arguments: [
                "sync", "--frozen", "--no-dev",
                "--project", configuration.runtimeProjectURL.path,
                "--python", "3.12", "--managed-python"
            ],
            environment: [
                "UV_PROJECT_ENVIRONMENT": configuration.stagingURL
                    .appendingPathComponent("runtime").path,
                "UV_PYTHON_INSTALL_DIR": configuration.rootURL
                    .appendingPathComponent("python").path,
                "UV_CACHE_DIR": cacheURL.appendingPathComponent("uv").path,
                "UV_LINK_MODE": "copy",
                "UV_NO_PROGRESS": "1"
            ],
            onOutput: nil
        )
        guard status == 0, fileManager.isExecutableFile(atPath: stagingPythonURL.path) else {
            throw VoiceEngineInstallerError.runtimeInstallationFailed
        }
    }

    private func prepareModel(
        onProgress: @escaping @Sendable (VoiceEngineInstallationProgress) async -> Void
    ) async throws {
        await onProgress(VoiceEngineInstallationProgress(
            phase: .downloadingModel,
            status: "約2.52GBの音声モデルを取得しています"
        ))
        let observer: @Sendable (String) async -> Void = { output in
            for line in output.split(whereSeparator: \Character.isNewline) {
                if let progress = VoiceEngineInstallationProgressParser.parse(String(line)) {
                    await onProgress(progress)
                }
            }
        }
        let status = try await commandRunner.run(
            executableURL: stagingPythonURL,
            arguments: [
                configuration.installationWorkerURL.path,
                "--model-root", stagingModelURL.path,
                "--cache-root", cacheURL.appendingPathComponent("huggingface").path
            ],
            environment: [
                "HF_HUB_DISABLE_TELEMETRY": "1",
                "DO_NOT_TRACK": "1",
                "PYTHONUNBUFFERED": "1"
            ],
            onOutput: observer
        )
        guard status == 0, modelLooksComplete() else {
            throw VoiceEngineInstallerError.modelInstallationFailed
        }
        let importStatus = try await commandRunner.run(
            executableURL: stagingPythonURL,
            arguments: ["-c", "import mlx_audio; from mlx_audio.tts.utils import load_model"],
            environment: ["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"],
            onOutput: nil
        )
        guard importStatus == 0 else {
            throw VoiceEngineInstallerError.runtimeInstallationFailed
        }
    }

}
