import Foundation

public enum VoiceEngineInstallationPhase: String, Codable, Equatable, Sendable {
    case idle
    case preparing
    case downloadingBootstrap
    case installingRuntime
    case downloadingModel
    case verifying
    case paused
    case ready
    case failed
    case deleting
}

public struct VoiceEngineInstallationProgress: Equatable, Sendable {
    public let phase: VoiceEngineInstallationPhase
    public let fraction: Double?
    public let status: String

    public init(
        phase: VoiceEngineInstallationPhase,
        fraction: Double? = nil,
        status: String
    ) {
        self.phase = phase
        self.fraction = fraction.map { min(max($0, 0), 1) }
        self.status = status
    }
}

public struct VoiceEngineInstallationPreflight: Equatable, Sendable {
    public let isHardwareSupported: Bool
    public let availableDiskBytes: Int64?
    public let requiredDiskBytes: Int64

    public init(
        isHardwareSupported: Bool,
        availableDiskBytes: Int64?,
        requiredDiskBytes: Int64
    ) {
        self.isHardwareSupported = isHardwareSupported
        self.availableDiskBytes = availableDiskBytes
        self.requiredDiskBytes = requiredDiskBytes
    }

    public var canInstall: Bool {
        guard isHardwareSupported else { return false }
        guard let availableDiskBytes else { return true }
        return availableDiskBytes >= requiredDiskBytes
    }
}

public enum VoiceEngineInstallationPolicy {
    public static let requiredDiskBytes: Int64 = 6_000_000_000

    public static func preflight(
        isAppleSilicon: Bool,
        availableDiskBytes: Int64?
    ) -> VoiceEngineInstallationPreflight {
        VoiceEngineInstallationPreflight(
            isHardwareSupported: isAppleSilicon,
            availableDiskBytes: availableDiskBytes,
            requiredDiskBytes: requiredDiskBytes
        )
    }
}

public struct VoiceEngineInstallationReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let engineIdentifier: String
    public let runtimeVersion: String
    public let modelIdentifier: String
    public let modelRevision: String
    public let installedAt: Date

    public init(
        schemaVersion: Int = 1,
        engineIdentifier: String,
        runtimeVersion: String,
        modelIdentifier: String,
        modelRevision: String,
        installedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.engineIdentifier = engineIdentifier
        self.runtimeVersion = runtimeVersion
        self.modelIdentifier = modelIdentifier
        self.modelRevision = modelRevision
        self.installedAt = installedAt
    }
}

public enum VoiceEngineInstallationProgressParser {
    public static func parse(_ output: String) -> VoiceEngineInstallationProgress? {
        if let data = output.data(using: .utf8),
           let event = try? JSONDecoder().decode(WorkerEvent.self, from: data),
           let phase = VoiceEngineInstallationPhase(rawValue: event.phase) {
            return VoiceEngineInstallationProgress(
                phase: phase,
                fraction: event.fraction,
                status: event.status
            )
        }
        let cleaned = stripControlSequences(output)
        guard let fraction = lastPercentage(in: cleaned).map({ $0 / 100 }) else {
            return nil
        }
        return VoiceEngineInstallationProgress(
            phase: .downloadingModel,
            fraction: fraction,
            status: "約2.52GBの音声モデルを取得しています"
        )
    }

    private static func lastPercentage(in text: String) -> Double? {
        let pattern = #"(?<![0-9])([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.matches(in: text, range: range).last,
              let valueRange = Range(match.range(at: 1), in: text),
              let value = Double(text[valueRange]), value >= 0, value <= 100 else {
            return nil
        }
        return value
    }

    private static func stripControlSequences(_ text: String) -> String {
        let pattern = #"\u{001B}\[[0-?]*[ -/]*[@-~]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }
}

private struct WorkerEvent: Decodable {
    let phase: String
    let status: String
    let fraction: Double?
}
