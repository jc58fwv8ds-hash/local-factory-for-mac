import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

struct VoiceEngineBenchmarkTests {
    @Test func repeatedFastGenerationBecomesConversationCandidate() throws {
        let report = try #require(VoiceEngineBenchmarkPolicy.report(
            engineIdentifier: engineID,
            measurements: [measurement(1, elapsed: 4_000, duration: 4_000),
                           measurement(2, elapsed: 2_000, duration: 4_000)]
        ))

        #expect(report.assessment == .conversationCandidate)
        #expect(report.initialMeasurement?.realTimeFactor == 1)
        #expect(report.repeatedMeasurement?.realTimeFactor == 0.5)
    }

    @Test func boundedDelayIsReportedAsUsableWithPause() throws {
        let report = try #require(VoiceEngineBenchmarkPolicy.report(
            engineIdentifier: engineID,
            measurements: [measurement(1, elapsed: 9_000, duration: 6_000),
                           measurement(2, elapsed: 6_000, duration: 4_000)]
        ))

        #expect(report.assessment == .usableWithPause)
    }

    @Test func slowFullClipGenerationStaysPreviewOnly() throws {
        let report = try #require(VoiceEngineBenchmarkPolicy.report(
            engineIdentifier: engineID,
            measurements: [measurement(1, elapsed: 14_000, duration: 4_000),
                           measurement(2, elapsed: 12_000, duration: 4_000)]
        ))

        #expect(report.assessment == .previewOnly)
    }

    @Test func malformedOrIncompleteMeasurementsAreRejected() {
        let incomplete = VoiceEngineBenchmarkPolicy.report(
            engineIdentifier: engineID,
            measurements: [measurement(1, elapsed: 1_000, duration: 3_000)]
        )
        let invalidAudio = VoiceEngineBenchmarkPolicy.report(
            engineIdentifier: engineID,
            measurements: [measurement(1, elapsed: 1_000, duration: 0),
                           measurement(2, elapsed: 1_000, duration: 3_000)]
        )

        #expect(incomplete == nil)
        #expect(invalidAudio == nil)
    }

    @Test func exclusiveOperationsAreBlockedWhileBenchmarkRuns() {
        let state = VoiceEngineOperationState(
            isRefreshing: false,
            isInstalling: false,
            isBenchmarking: true
        )

        #expect(VoiceEngineOperationPolicy.blocker(for: .removal, state: state) == .benchmark)
        #expect(VoiceEngineOperationPolicy.blocker(for: .refresh, state: state) == .benchmark)
        #expect(VoiceEngineOperationPolicy.blocker(for: .installation, state: state) == .benchmark)
    }

    @Test func idleEngineAllowsEveryExclusiveOperation() {
        let state = VoiceEngineOperationState(
            isRefreshing: false,
            isInstalling: false,
            isBenchmarking: false
        )
        let operations: [VoiceEngineExclusiveOperation] = [
            .refresh, .installation, .benchmark, .removal, .partialDiscard
        ]

        for operation in operations {
            #expect(VoiceEngineOperationPolicy.blocker(for: operation, state: state) == nil)
        }
    }

    @Test @MainActor func removalCannotStartDuringBenchmark() async throws {
        let installer = BenchmarkBlockingInstaller()
        let session = VoiceEngineBenchmarkSession()
        let store = VoiceEngineStore(installer: installer, benchmarkSession: session)
        session.start(capsuleID: UUID(), synthesizer: HoldingBenchmarkSynthesizer())

        #expect(session.isRunning)
        #expect(store.isBenchmarking)
        store.confirmRemoval()

        #expect(await installer.removalCount == 0)
        #expect(store.errorMessage?.contains("性能を測定中") == true)
        session.stop()
        while session.isRunning {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!store.isBenchmarking)
    }

    @Test @MainActor func stoppingKeepsStoreBusyUntilSynthesisActuallyStops() async throws {
        let session = VoiceEngineBenchmarkSession()
        let store = VoiceEngineStore(benchmarkSession: session)
        session.start(capsuleID: UUID(), synthesizer: HoldingBenchmarkSynthesizer())

        store.stopBenchmark()

        while session.isRunning {
            #expect(store.isBenchmarking)
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!store.isBenchmarking)
    }

    @Test @MainActor func sessionRunsExactlyTwoMeasurementsWithoutKeepingAudio() async throws {
        let session = VoiceEngineBenchmarkSession()
        let synthesizer = BenchmarkSynthesizerFixture()

        session.start(capsuleID: UUID(), synthesizer: synthesizer)
        while session.isRunning {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(synthesizer.callCount == 2)
        #expect(session.report?.measurements.count == 2)
        #expect(session.errorMessage == nil)
    }

    private var engineID: String { VoiceEngineCatalog.qwen3TTSMLX.id }

    private func measurement(
        _ sequence: Int,
        elapsed: Int,
        duration: Int
    ) -> VoiceEngineBenchmarkMeasurement {
        VoiceEngineBenchmarkMeasurement(
            sequence: sequence,
            elapsedMilliseconds: elapsed,
            audioDurationMilliseconds: duration,
            sampleRate: 24_000,
            audioByteCount: 192_044
        )
    }
}

@MainActor
private final class BenchmarkSynthesizerFixture: VoiceEngineBenchmarkSynthesizing {
    private(set) var callCount = 0

    func synthesize(text: String, capsuleID: UUID) async throws -> VoiceSynthesisAudio {
        callCount += 1
        return VoiceSynthesisAudio(
            wavData: Data(repeating: 0, count: 1_024),
            sampleRate: 24_000,
            durationMilliseconds: 3_000
        )
    }
}

@MainActor
private final class HoldingBenchmarkSynthesizer: VoiceEngineBenchmarkSynthesizing {
    func synthesize(text: String, capsuleID: UUID) async throws -> VoiceSynthesisAudio {
        try await Task.sleep(for: .seconds(30))
        return VoiceSynthesisAudio(
            wavData: Data(repeating: 0, count: 1_024),
            sampleRate: 24_000,
            durationMilliseconds: 3_000
        )
    }
}

private actor BenchmarkBlockingInstaller: VoiceEngineInstalling {
    private(set) var removalCount = 0

    func preflight() -> VoiceEngineInstallationPreflight {
        VoiceEngineInstallationPolicy.preflight(
            isAppleSilicon: true,
            availableDiskBytes: VoiceEngineInstallationPolicy.requiredDiskBytes
        )
    }

    func hasResumableInstallation() -> Bool { false }

    func install(
        onProgress: @escaping @Sendable (VoiceEngineInstallationProgress) async -> Void
    ) async throws {}

    func discardPartialInstallation() async throws {}

    func removeInstallation() async throws {
        removalCount += 1
    }
}
