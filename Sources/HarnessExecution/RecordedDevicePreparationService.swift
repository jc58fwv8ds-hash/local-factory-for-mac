import CryptoKit
import Foundation
import HarnessCore
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence

/// Records a read-only observation, never product completion or a durable permission grant.
public actor RecordedDevicePreparationService: DevicePreparationProviding {
    private let provider: any DevicePreparationProviding
    private let directory: URL
    public private(set) var lastRunDirectory: URL?

    public init(provider: any DevicePreparationProviding = LocalDevicePreparationService(), directory: URL? = nil) {
        self.provider = provider
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness/DevicePreparation", isDirectory: true)
    }

    public func inspect(deviceIdentifier: String) async throws -> DevicePreparationSnapshot {
        guard UUID(uuidString: deviceIdentifier) != nil else { throw DevicePreparationError.invalidIdentifier }
        try Task.checkCancellation()
        let runID = UUID()
        let runDirectory = directory.appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        lastRunDirectory = runDirectory
        let engine = try KernelEngine(runID: runID,
            journal: FileKernelJournal(directory: runDirectory.appendingPathComponent("events")))
        let step = KernelStep(instruction: "対象端末の接続・開発準備状態を読み取り確認する")
        let requirement = VerificationRequirement(criterion: "対象端末の現在の準備条件を照合する", kind: .acceptance)
        try await engine.record(.planned(KernelPlan(userRequest: step.instruction,
            modelIdentifier: "deterministic-device-preparation", steps: [step], requirements: [requirement])))
        let attempt = UUID()
        try await engine.record(.stepStarted(stepID: step.id, attemptID: attempt))
        do {
            let observation = try await provider.inspect(deviceIdentifier: deviceIdentifier)
            try Task.checkCancellation()
            guard observation.deviceIdentifier.caseInsensitiveCompare(deviceIdentifier) == .orderedSame else {
                throw DevicePreparationError.invalidIdentifier
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(observation)
            let receipt = runDirectory.appendingPathComponent("observation.json")
            try data.write(to: receipt, options: .atomic)
            guard try Data(contentsOf: receipt) == data else { throw DevicePreparationFailure.invalidResponse }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try await engine.record(.decisionRecorded("観測結果: observation.json#sha256=\(hash)"))
            try await engine.record(.stepFinished(attemptID: attempt, succeeded: observation.isReady(for: deviceIdentifier)))
            // A fresh observation must be obtained after resuming; do not replay it as current readiness.
            try await engine.record(.paused(reason: observation.summary()))
            return observation
        } catch {
            _ = try? await engine.record(.paused(reason: "端末確認が中断されたか、観測記録を確認できませんでした。再開時に新しく照会します。"))
            throw error
        }
    }
}
