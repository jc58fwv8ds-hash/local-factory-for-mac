import Foundation

public struct InstalledModel: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(runtime.rawValue):\(identifier)" }
    public let identifier: String
    public let displayName: String
    public let sizeLabel: String
    public let runtime: RuntimeKind
    public let localPath: String?
    public let capabilities: Set<VisualModelCapability>?

    public init(
        identifier: String,
        displayName: String,
        sizeLabel: String,
        runtime: RuntimeKind,
        localPath: String? = nil,
        capabilities: Set<VisualModelCapability>? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.sizeLabel = sizeLabel
        self.runtime = runtime
        self.localPath = localPath
        self.capabilities = capabilities
    }

    public func withCapabilities(_ capabilities: Set<VisualModelCapability>) -> InstalledModel {
        InstalledModel(
            identifier: identifier,
            displayName: displayName,
            sizeLabel: sizeLabel,
            runtime: runtime,
            localPath: localPath,
            capabilities: capabilities
        )
    }
}

public enum RuntimeAvailability: String, Codable, Sendable {
    case ready
    case installedButStopped
    case notInstalled
    case timedOut
    case failed
}

public struct RuntimeReport: Identifiable, Codable, Equatable, Sendable {
    public var id: RuntimeKind { runtime.kind }
    public let runtime: RuntimeCandidate
    public let availability: RuntimeAvailability
    public let detail: String

    public init(runtime: RuntimeCandidate, availability: RuntimeAvailability, detail: String) {
        self.runtime = runtime
        self.availability = availability
        self.detail = detail
    }
}

public struct ModelInventory: Codable, Equatable, Sendable {
    public let models: [InstalledModel]
    public let runtimes: [RuntimeReport]

    public init(models: [InstalledModel], runtimes: [RuntimeReport]) {
        self.models = models
        self.runtimes = runtimes
    }
}

public enum ModelManagementError: LocalizedError, Sendable {
    case runtimeUnavailable(RuntimeKind)
    case unsupportedOperation(String)
    case commandFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let runtime):
            "\(runtime.rawValue)が利用できません。"
        case .unsupportedOperation(let message):
            message
        case .commandFailed(let message):
            message
        case .timedOut(let command):
            "\(command)の応答がありませんでした。"
        }
    }
}
