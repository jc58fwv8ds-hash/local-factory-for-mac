import Foundation

public enum RuntimeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case harness = "Harness 内蔵AI"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    /// Local llama.cpp fork (github.com/StayLameBro/backburner) serving Qwen3.8-27B on 127.0.0.1:8080, OpenAI-compatible.
    /// The App starts it on demand (BackburnerServer); there is no model download through the App.
    case backburner = "Backburner"

    public var id: String { rawValue }
}

public struct RuntimeCandidate: Identifiable, Codable, Equatable, Sendable {
    public var id: RuntimeKind { kind }
    public let kind: RuntimeKind
    public let executablePath: String
    public let isInstalled: Bool

    public init(kind: RuntimeKind, executablePath: String, isInstalled: Bool) {
        self.kind = kind
        self.executablePath = executablePath
        self.isInstalled = isInstalled
    }
}

public struct ModelRuntimeProbe: Sendable {
    public init() {}

    public func detect(fileManager: FileManager = .default) -> [RuntimeCandidate] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let bundledRuntime = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Runtime/llama-server")
            .path
        let definitions: [(RuntimeKind, [String])] = [
            (.harness, [bundledRuntime]),
            (.ollama, ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]),
            (.lmStudio, ["\(home)/.lmstudio/bin/lms"]),
            (.backburner, ["\(home)/backburner/scripts/serve.sh"])
        ]

        return definitions.map { kind, paths in
            let installedPath = paths.first(where: fileManager.isExecutableFile(atPath:))
            return RuntimeCandidate(
                kind: kind,
                executablePath: installedPath ?? paths[0],
                isInstalled: installedPath != nil
            )
        }
    }
}
