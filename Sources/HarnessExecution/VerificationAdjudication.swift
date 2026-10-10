import Foundation

/// Adjudication is separate from raw receipts. Never infers a cause from a signal number.
public enum VerificationAdjudication {
    public enum Kind: String, Codable, Sendable {
        case assertion = "TEST_ASSERTION_FAILURE"
        case signal = "TEST_RUNTIME_SIGNAL"
        case crash = "TEST_RUNTIME_CRASH"
        case timeout = "TEST_TIMEOUT"
        case infrastructure = "TEST_INFRASTRUCTURE_FAILURE"
        case isolation = "EXECUTION_ISOLATION_DENIAL"
        case unknown = "UNKNOWN_VERIFICATION_FAILURE"
    }
    public struct Verdict: Codable, Sendable, Equatable {
        public let kind: Kind
        public let processStarted: Bool
        public let terminationType: String
        public let isolationDenial: Bool
        public var runtimeRepairEligible: Bool { !isolationDenial && processStarted && (kind == .signal || kind == .crash) }
    }
    public static func classify(output: String, timedOut: Bool = false,
                                setupDenied: Bool = false, crashReportMatched: Bool = false) -> Verdict {
        let started = output.contains("Test run started") || output.contains("Test Suite ")
        // Specific launcher/policy diagnostics only; an arbitrary nonzero exit is not denial.
        let denied = setupDenied || output.contains("sandbox-exec: sandbox_apply:")
            || output.contains("sandbox-exec: execvp:") || output.contains("Sandbox: ") && output.contains("deny(")
        let kind: Kind
        let termination: String
        if denied { kind = .isolation; termination = "denied" }
        else if timedOut { kind = .timeout; termination = "timeout" }
        else if started && crashReportMatched { kind = .crash; termination = "crashReport" }
        else if started && output.contains("exited with unexpected signal code") { kind = .signal; termination = "signal" }
        else if started && (output.contains("Expectation failed") || output.contains("XCTAssert") || output.contains("recorded an issue")) {
            kind = .assertion; termination = "exit"
        } else if output.contains("no tests found") || output.contains("error: no Package.swift") || output.contains("failed to load test bundle") {
            kind = .infrastructure; termination = "exit"
        } else { kind = .unknown; termination = "unknown" }
        return .init(kind: kind, processStarted: started, terminationType: termination, isolationDenial: denied)
    }
}
