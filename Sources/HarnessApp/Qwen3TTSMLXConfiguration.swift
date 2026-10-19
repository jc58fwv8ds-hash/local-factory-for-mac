import Foundation
import HarnessCore

struct Qwen3TTSMLXConfiguration: Equatable, Sendable {
    let rootURL: URL
    let activeURL: URL
    let stagingURL: URL
    let pythonExecutableURL: URL
    let workerURL: URL
    /// The resident speaker (model loaded once, pieces streamed): `qwen3_tts_server.py` next to the worker.
    var serverURL: URL { workerURL.deletingLastPathComponent().appendingPathComponent("qwen3_tts_server.py") }
    let installationWorkerURL: URL
    let runtimeProjectURL: URL
    let modelURL: URL
    let receiptURL: URL
    let bootstrapArchiveURL: URL
    let uvExecutableURL: URL
    let uvArchiveRemoteURL: URL
    let uvArchiveSHA256: String

    static let defaultUVArchiveRemoteURL = URL(string:
        "https://github.com/astral-sh/uv/releases/download/0.12.9/uv-aarch64-apple-darwin.tar.gz"
    )!
    static let defaultUVArchiveSHA256 =
        "301f72afaf54060f92da7016cb0115bd077f43a9c8e39c1d8170a0bac80fd398"

    init(
        rootURL: URL,
        workerURL: URL,
        installationWorkerURL: URL? = nil,
        runtimeProjectURL: URL? = nil,
        uvArchiveRemoteURL: URL = Self.defaultUVArchiveRemoteURL,
        uvArchiveSHA256: String = Self.defaultUVArchiveSHA256
    ) {
        self.rootURL = rootURL
        self.activeURL = rootURL.appendingPathComponent("active", isDirectory: true)
        self.stagingURL = rootURL.appendingPathComponent("staging", isDirectory: true)
        self.pythonExecutableURL = activeURL
            .appendingPathComponent("runtime/bin/python3")
        self.workerURL = workerURL
        self.installationWorkerURL = installationWorkerURL
            ?? URL(fileURLWithPath: "/nonexistent/harness-voice-engine-installer.py")
        self.runtimeProjectURL = runtimeProjectURL
            ?? URL(fileURLWithPath: "/nonexistent/harness-voice-engine-runtime")
        self.modelURL = activeURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(VoiceEngineCatalog.qwen3TTSMLXVariant.folderName, isDirectory: true)
        self.receiptURL = activeURL.appendingPathComponent("installation.json")
        self.bootstrapArchiveURL = rootURL
            .appendingPathComponent("bootstrap", isDirectory: true)
            .appendingPathComponent("uv.tar.gz")
        self.uvExecutableURL = rootURL
            .appendingPathComponent("bootstrap/uv-aarch64-apple-darwin/uv")
        self.uvArchiveRemoteURL = uvArchiveRemoteURL
        self.uvArchiveSHA256 = uvArchiveSHA256
    }

    static func managed() -> Self {
        let packagedBundleURL = Bundle.main.resourceURL?
            .appendingPathComponent("Harness_HarnessApp.bundle", isDirectory: true)
        let packagedBundle = packagedBundleURL.flatMap { Bundle(url: $0) }
        let worker = packagedBundle?.url(
            forResource: "qwen3_tts_worker",
            withExtension: "py"
        ) ?? Bundle.module.url(
            forResource: "qwen3_tts_worker",
            withExtension: "py"
        ) ?? URL(fileURLWithPath: "/nonexistent/harness-qwen3-tts-worker.py")
        let installationWorker = packagedBundle?.url(
            forResource: "voice_engine_install_worker",
            withExtension: "py"
        ) ?? Bundle.module.url(
            forResource: "voice_engine_install_worker",
            withExtension: "py"
        ) ?? URL(fileURLWithPath: "/nonexistent/harness-voice-engine-installer.py")
        let runtimeProject = packagedBundle?.url(
            forResource: "VoiceEngineRuntime",
            withExtension: nil
        ) ?? Bundle.module.url(
            forResource: "VoiceEngineRuntime",
            withExtension: nil
        ) ?? URL(fileURLWithPath: "/nonexistent/harness-voice-engine-runtime")
        return Self(
            rootURL: HarnessAppEnvironment.voiceEngineRootURL()
                .appendingPathComponent(VoiceEngineCatalog.qwen3TTSMLX.id, isDirectory: true),
            workerURL: worker,
            installationWorkerURL: installationWorker,
            runtimeProjectURL: runtimeProject
        )
    }
}
