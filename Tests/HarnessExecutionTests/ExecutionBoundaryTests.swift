import HarnessExecution
import Testing

struct ExecutionBoundaryTests {
    @Test func externalDispatchRequiresFreshCleanReadiness() {
        #expect(ExternalDispatchReadiness(ready: true, reasons: [], inferenceCalls: 0).canPrepareExternalDispatch)
        #expect(!ExternalDispatchReadiness(ready: true, reasons: ["provider"], inferenceCalls: 0).canPrepareExternalDispatch)
        #expect(!ExternalDispatchReadiness(ready: true, reasons: [], inferenceCalls: 1).canPrepareExternalDispatch)
        #expect(!ExternalDispatchReadiness(schemaVersion: 2, ready: true, reasons: [], inferenceCalls: 0).canPrepareExternalDispatch)
    }

    @Test func physicalAcceptanceCannotCloseUntilEveryStepIsObserved() {
        var complete = PhysicalAcceptanceGate(recording: true, iphoneReceipt: true, macTransfer: true,
            transcription: true, editableProposal: true, calendarConfirmation: true, calendarSaved: true)
        #expect(!complete.isComplete) // Legacy seven-step evidence is insufficient.
        complete.sessionEvidence = Set(PhysicalAcceptanceGate.SessionEvidence.allCases)
        #expect(complete.isComplete)
        #expect(!PhysicalAcceptanceGate(recording: true, iphoneReceipt: true, macTransfer: true,
            transcription: true, editableProposal: true, calendarConfirmation: true, calendarSaved: false).isComplete)
    }
}
