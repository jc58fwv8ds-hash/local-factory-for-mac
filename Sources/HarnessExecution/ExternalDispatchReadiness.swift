import Foundation

/// Typed execution boundary shared by future adapters. A positive result is only
/// possible after a fresh, no-inference readiness probe has cleared every reason.
public struct ExternalDispatchReadiness: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let ready: Bool
    public let reasons: [String]
    public let inferenceCalls: Int

    public init(schemaVersion: Int = 1, ready: Bool, reasons: [String], inferenceCalls: Int) {
        self.schemaVersion = schemaVersion
        self.ready = ready
        self.reasons = reasons
        self.inferenceCalls = inferenceCalls
    }

    public var canPrepareExternalDispatch: Bool {
        schemaVersion == 1 && ready && reasons.isEmpty && inferenceCalls == 0
    }
}

public struct PhysicalAcceptanceGate: Codable, Equatable, Sendable {
    public enum SessionEvidence: String, Codable, CaseIterable, Sendable {
        case backgroundRecording, chunkGenerated, watchDurableCommit, iphoneDurableInbox
        case cloudKitPrivateSync, macChecksumVerified, conversationAnalysis, memoryCandidate
        case taskCandidate, memoryCommitted, watchSessionEnded
    }
    public var sessionEvidence: Set<SessionEvidence>? = nil
    public let recording: Bool
    public let iphoneReceipt: Bool
    public let macTransfer: Bool
    public let transcription: Bool
    public let editableProposal: Bool
    public let calendarConfirmation: Bool
    public let calendarSaved: Bool

    public init(recording: Bool, iphoneReceipt: Bool, macTransfer: Bool,
                transcription: Bool, editableProposal: Bool,
                calendarConfirmation: Bool, calendarSaved: Bool) {
        self.recording = recording; self.iphoneReceipt = iphoneReceipt
        self.macTransfer = macTransfer; self.transcription = transcription
        self.editableProposal = editableProposal; self.calendarConfirmation = calendarConfirmation
        self.calendarSaved = calendarSaved
    }

    public var isComplete: Bool {
        recording && iphoneReceipt && macTransfer && transcription && editableProposal
            && calendarConfirmation && calendarSaved
            && sessionEvidence == Set(SessionEvidence.allCases)
    }
}
