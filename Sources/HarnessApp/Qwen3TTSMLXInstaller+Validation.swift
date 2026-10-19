import CryptoKit
import Foundation
import HarnessCore

extension Qwen3TTSMLXInstaller {
    func downloadBootstrapArchive(resuming: Bool) async throws -> Int32 {
        var arguments = ["--fail", "--location", "--retry", "3"]
        if resuming {
            arguments += ["--continue-at", "-"]
        }
        arguments += [
            "--output", configuration.bootstrapArchiveURL.path,
            configuration.uvArchiveRemoteURL.absoluteString
        ]
        return try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: arguments,
            environment: [:],
            onOutput: nil
        )
    }

    func resourcesArePresent() -> Bool {
        fileManager.isReadableFile(atPath: configuration.installationWorkerURL.path)
            && fileManager.fileExists(atPath: configuration.runtimeProjectURL
                .appendingPathComponent("pyproject.toml").path)
            && fileManager.fileExists(atPath: configuration.runtimeProjectURL
                .appendingPathComponent("uv.lock").path)
    }

    func modelLooksComplete() -> Bool {
        VoiceEngineCatalog.qwen3TTSMLXVariant.expectedFiles.allSatisfy { file in
            let url = stagingModelURL.appendingPathComponent(file.path)
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.bytes
        }
    }

    func writeFinalReceipt() throws {
        let target = configuration.stagingURL.appendingPathComponent("installation.json")
        try JSONEncoder().encode(receipt()).write(to: target, options: .atomic)
        try setPermissions(0o600, at: target)
        try? fileManager.removeItem(at: partialReceiptURL)
    }

    func receipt(installedAt: Date = .now) -> VoiceEngineInstallationReceipt {
        VoiceEngineInstallationReceipt(
            engineIdentifier: VoiceEngineCatalog.qwen3TTSMLX.id,
            runtimeVersion: VoiceEngineCatalog.qwen3TTSMLXRuntimeVersion,
            modelIdentifier: VoiceEngineCatalog.qwen3TTSMLX.modelIdentifier,
            modelRevision: VoiceEngineCatalog.qwen3TTSMLXModelRevision,
            installedAt: installedAt
        )
    }

    func validateManagedRoot() throws {
        let root = configuration.rootURL.standardizedFileURL
        guard root.path != "/", root.lastPathComponent == VoiceEngineCatalog.qwen3TTSMLX.id,
              root.deletingLastPathComponent().path != "/" else {
            throw VoiceEngineInstallerError.activationFailed
        }
    }

    func existingStorageURL() -> URL {
        var candidate = configuration.rootURL.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    func removeEmptyRootIfPossible() throws {
        guard !fileManager.fileExists(atPath: configuration.activeURL.path),
              let contents = try? fileManager.contentsOfDirectory(
                at: configuration.rootURL,
                includingPropertiesForKeys: nil
              ), contents.isEmpty else { return }
        try fileManager.removeItem(at: configuration.rootURL)
    }

    func sha256IfPresent(at url: URL) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try sha256(at: url)
    }

    func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func setPermissions(_ permissions: Int, at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    func report(
        _ phase: VoiceEngineInstallationPhase,
        _ status: String,
        to observer: @escaping @Sendable (VoiceEngineInstallationProgress) async -> Void
    ) async throws {
        try Task.checkCancellation()
        await observer(VoiceEngineInstallationProgress(phase: phase, status: status))
    }
}
