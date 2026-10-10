public enum RemoteInvitationOutcome: Equatable, Sendable {
    case accept
    case rejectInvalidCode
    case rejectBusy
    case rejectInactive

    public var acceptsConnection: Bool { self == .accept }
    public var reportsInvalidCode: Bool { self == .rejectInvalidCode }
}

public enum RemoteInvitationPolicy {
    public static func decide(
        isAdvertiserActive: Bool,
        pairingCodeMatches: Bool,
        hasConnectedPeer: Bool
    ) -> RemoteInvitationOutcome {
        guard isAdvertiserActive else { return .rejectInactive }
        guard !hasConnectedPeer else { return .rejectBusy }
        guard pairingCodeMatches else { return .rejectInvalidCode }
        return .accept
    }
}
