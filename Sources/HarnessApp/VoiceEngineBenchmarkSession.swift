import Foundation
import HarnessCore
import Observation

@MainActor
protocol VoiceEngineBenchmarkSynthesizing: AnyObject {
    func synthesize(text: String, capsuleID: UUID) async throws -> VoiceSynthesisAudio
}

extension VoiceEngineStore: VoiceEngineBenchmarkSynthesizing {}

enum VoiceEngineBenchmarkSessionError: LocalizedError {
    case invalidMeasurements

    var errorDescription: String? {
        "生成結果を安全に測定できませんでした。音声エンジンを再確認してください。"
    }
}

@MainActor
@Observable
final class VoiceEngineBenchmarkSession {
    private(set) var currentStep = 0
    private(set) var report: VoiceEngineBenchmarkReport?
    private(set) var errorMessage: String?
    private(set) var cancellationMessage: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runningObserver: ((Bool) -> Void)?

    var isRunning: Bool { task != nil }

    func observeRunning(_ observer: @escaping (Bool) -> Void) {
        runningObserver = observer
        observer(isRunning)
    }

    func start(
        capsuleID: UUID,
        synthesizer: any VoiceEngineBenchmarkSynthesizing
    ) {
        guard task == nil else { return }
        report = nil
        errorMessage = nil
        cancellationMessage = nil
        currentStep = 1
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let measurements = try await measure(
                    capsuleID: capsuleID,
                    synthesizer: synthesizer
                )
                try Task.checkCancellation()
                guard let report = VoiceEngineBenchmarkPolicy.report(
                    engineIdentifier: VoiceEngineCatalog.qwen3TTSMLX.id,
                    measurements: measurements
                ) else {
                    throw VoiceEngineBenchmarkSessionError.invalidMeasurements
                }
                self.report = report
            } catch is CancellationError {
                self.cancellationMessage = "測定を中止しました。生成音声は保存していません。"
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.currentStep = 0
            self.task = nil
            self.runningObserver?(false)
        }
        runningObserver?(true)
    }

    func stop() {
        task?.cancel()
    }

    private func measure(
        capsuleID: UUID,
        synthesizer: any VoiceEngineBenchmarkSynthesizing
    ) async throws -> [VoiceEngineBenchmarkMeasurement] {
        var measurements: [VoiceEngineBenchmarkMeasurement] = []
        for sequence in 1...VoiceEngineBenchmarkPolicy.requiredMeasurementCount {
            currentStep = sequence
            let started = ContinuousClock.now
            let audio = try await synthesizer.synthesize(
                text: Self.sampleText,
                capsuleID: capsuleID
            )
            let elapsed = ContinuousClock.now - started
            try Task.checkCancellation()
            measurements.append(VoiceEngineBenchmarkMeasurement(
                sequence: sequence,
                elapsedMilliseconds: max(1, Self.milliseconds(elapsed)),
                audioDurationMilliseconds: audio.durationMilliseconds,
                sampleRate: audio.sampleRate,
                audioByteCount: audio.wavData.count
            ))
        }
        return measurements
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        let seconds = parts.seconds.multipliedReportingOverflow(by: 1_000)
        guard !seconds.overflow else { return 180_001 }
        let subsecond = parts.attoseconds / 1_000_000_000_000_000
        return Int(clamping: seconds.partialValue + subsecond)
    }

    private static let sampleText =
        "承知しました。状況を確認して、必要な変更を安全な順番で進めます。"
}
