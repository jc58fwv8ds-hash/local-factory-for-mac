public enum WorkspaceInteractionOperation: Equatable, Sendable {
    case startVoiceConversation
    case submitInstruction
    case submitVoiceTurn
    case openComputerOperator
    case prepareComputerOperation
    case executeComputerOperation
    case changeSelectedProject
}

public enum WorkspaceInteractionBlocker: Equatable, Sendable {
    case modelGeneration
    case voiceConversation
    case computerOperator
    case resumableProjectWork
    case pendingComputerOperation
}

public struct WorkspaceInteractionState: Equatable, Sendable {
    public let isGenerating: Bool
    public let isVoiceConversationActive: Bool
    public let isComputerOperatorBusy: Bool
    public let hasResumableProjectWork: Bool
    public let hasPendingComputerOperation: Bool

    public init(
        isGenerating: Bool,
        isVoiceConversationActive: Bool,
        isComputerOperatorBusy: Bool,
        hasResumableProjectWork: Bool,
        hasPendingComputerOperation: Bool
    ) {
        self.isGenerating = isGenerating
        self.isVoiceConversationActive = isVoiceConversationActive
        self.isComputerOperatorBusy = isComputerOperatorBusy
        self.hasResumableProjectWork = hasResumableProjectWork
        self.hasPendingComputerOperation = hasPendingComputerOperation
    }
}

public enum WorkspaceInteractionPolicy {
    public static func blocker(
        for operation: WorkspaceInteractionOperation,
        state: WorkspaceInteractionState
    ) -> WorkspaceInteractionBlocker? {
        switch operation {
        case .startVoiceConversation:
            return firstBlocker(
                state,
                includesVoice: false,
                includesComputerCheckpoint: true
            )
        case .submitInstruction:
            return firstBlocker(
                state,
                includesVoice: true,
                includesComputerCheckpoint: true
            )
        case .submitVoiceTurn:
            return firstBlocker(
                state,
                includesVoice: false,
                includesComputerCheckpoint: true
            )
        case .openComputerOperator:
            if state.isGenerating { return .modelGeneration }
            if state.isVoiceConversationActive { return .voiceConversation }
            return nil
        case .prepareComputerOperation:
            return firstBlocker(
                state,
                includesVoice: true,
                includesComputerCheckpoint: true
            )
        case .executeComputerOperation:
            if state.isGenerating { return .modelGeneration }
            if state.isVoiceConversationActive { return .voiceConversation }
            if state.hasResumableProjectWork { return .resumableProjectWork }
            return nil
        case .changeSelectedProject:
            if state.isVoiceConversationActive { return .voiceConversation }
            if state.isComputerOperatorBusy { return .computerOperator }
            return nil
        }
    }

    private static func firstBlocker(
        _ state: WorkspaceInteractionState,
        includesVoice: Bool,
        includesComputerCheckpoint: Bool
    ) -> WorkspaceInteractionBlocker? {
        if state.isGenerating { return .modelGeneration }
        if includesVoice, state.isVoiceConversationActive { return .voiceConversation }
        if state.isComputerOperatorBusy { return .computerOperator }
        if state.hasResumableProjectWork { return .resumableProjectWork }
        if includesComputerCheckpoint, state.hasPendingComputerOperation {
            return .pendingComputerOperation
        }
        return nil
    }
}
