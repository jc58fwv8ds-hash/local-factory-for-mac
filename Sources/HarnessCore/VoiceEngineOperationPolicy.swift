public enum VoiceEngineExclusiveOperation: Equatable, Sendable {
    case refresh
    case installation
    case benchmark
    case removal
    case partialDiscard
}

public enum VoiceEngineOperationBlocker: Equatable, Sendable {
    case refresh
    case installation
    case benchmark
}

public struct VoiceEngineOperationState: Equatable, Sendable {
    public let isRefreshing: Bool
    public let isInstalling: Bool
    public let isBenchmarking: Bool

    public init(
        isRefreshing: Bool,
        isInstalling: Bool,
        isBenchmarking: Bool
    ) {
        self.isRefreshing = isRefreshing
        self.isInstalling = isInstalling
        self.isBenchmarking = isBenchmarking
    }
}

public enum VoiceEngineOperationPolicy {
    public static func blocker(
        for operation: VoiceEngineExclusiveOperation,
        state: VoiceEngineOperationState
    ) -> VoiceEngineOperationBlocker? {
        _ = operation
        if state.isInstalling { return .installation }
        if state.isBenchmarking { return .benchmark }
        if state.isRefreshing { return .refresh }
        return nil
    }
}
