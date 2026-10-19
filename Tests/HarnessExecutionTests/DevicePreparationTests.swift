import Foundation
import HarnessExecution
import HarnessKernelContracts
import HarnessKernelPersistence
@testable import HarnessCore
import Testing

struct DevicePreparationTests {
    private let identifier = "11111111-1111-1111-1111-111111111111"

    @Test func completeDetailsDoNotProveLockState() throws {
        let value = try DevicePreparationParser.details(details(), identifier: identifier, observedAt: .now)
        #expect(value.developerMode == .met)
        #expect(value.ddiServices == .met)
        #expect(value.passcode == .unknown)
        #expect(!value.isReady(for: identifier))
    }

    @Test func missingAndNovelValuesRemainUnknown() throws {
        let value = try DevicePreparationParser.details(details(connection: #"{"pairingState":"paired","tunnelState":"connecting"}"#,
            properties: #"{"bootState":"booted","developerModeStatus":"futureValue"}"#), identifier: identifier, observedAt: .now)
        #expect(value.pairing == .met)
        #expect(value.tunnel == .unknown)
        #expect(value.developerMode == .unknown)
        #expect(value.ddiServices == .unknown)
        #expect(!value.isReady(for: identifier))
        #expect(value.summary().contains("一部"))
    }

    @Test func explicitDisabledIsNotUnknown() throws {
        let value = try DevicePreparationParser.details(details(properties:
            #"{"developerModeStatus":"disabled","ddiServicesAvailable":false}"#), identifier: identifier, observedAt: .now)
        #expect(value.developerMode == .notMet)
        #expect(value.ddiServices == .notMet)
        #expect(value.summary().contains("WidgetKit"))
    }

    @Test(arguments: ["version", "target", "outcome", "type", "malformed", "oversized"])
    func rejectsUntrustedEnvelope(kind: String) {
        let data: Data
        switch kind {
        case "version": data = details(version: 6)
        case "target": data = details(id: "22222222-2222-2222-2222-222222222222")
        case "outcome": data = details(outcome: "failure")
        case "type": data = details(properties: #"{"ddiServicesAvailable":"true"}"#)
        case "oversized": data = Data(repeating: 32, count: 2_000_001)
        default: data = Data("{".utf8)
        }
        #expect(throws: DevicePreparationFailure.invalidResponse) {
            try DevicePreparationParser.details(data, identifier: identifier, observedAt: .now)
        }
    }

    @Test func lockQueryDoesNotUseHistoricalBootFlags() throws {
        #expect(try DevicePreparationParser.lock(lock(#""unlockedSinceBoot":true"#), identifier: identifier) == .unknown)
        #expect(try DevicePreparationParser.lock(lock(#""unlockedSinceBoot":true,"passcodeRequired":true"#), identifier: identifier) == .notMet)
        #expect(try DevicePreparationParser.lock(lock(#""passcodeRequired":false"#), identifier: identifier) == .met)
        #expect(throws: DevicePreparationFailure.invalidResponse) {
            try DevicePreparationParser.lock(lock(#""passcodeRequired":false"#), identifier: UUID().uuidString)
        }
    }

    @Test func freshnessTargetAndFailureGate() {
        let now = Date()
        let ready = complete(at: now)
        #expect(ready.isReady(for: identifier, at: now))
        #expect(!ready.isReady(for: identifier, at: now.addingTimeInterval(61)))
        #expect(!ready.isReady(for: identifier, at: now.addingTimeInterval(-1)))
        #expect(!ready.isReady(for: UUID().uuidString, at: now))
        let failed = DevicePreparationSnapshot(deviceIdentifier: identifier, observedAt: now,
            pairing: .met, tunnel: .met, developerMode: .met, ddiServices: .met, passcode: .met,
            lockFailure: .commandFailed)
        #expect(!failed.isReady(for: identifier, at: now))
    }

    @Test func legacyBootedInventoryCannotAuthorizeRun() {
        let device = PhysicalAppleDevice(id: identifier, name: "Fixture", modelName: "iPhone",
            osVersion: "26.6", connection: .wired, isPaired: true, isDeveloperModeEnabled: true, isBooted: true)
        let project = PhysicalDeviceProjectConfiguration(containerName: "App", scheme: "App", productName: "App",
            bundleIdentifier: "local.fixture.app", signingStyle: .automatic, hasDevelopmentTeam: true, isIOSApplication: true)
        #expect(!PhysicalDeviceReadinessEvaluator.evaluate(device: device, project: project).canRun)
        #expect(PhysicalDeviceReadinessEvaluator.evaluate(device: device, project: project,
            preparation: complete()).canRun)
    }

    @Test(arguments: [false, true])
    func recordsObservationWithoutProductCompletion(blocked: Bool) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = blocked ? DevicePreparationSnapshot(deviceIdentifier: identifier, detailsFailure: .timedOut) : complete()
        let service = RecordedDevicePreparationService(provider: Stub(value: expected), directory: root)
        #expect(try await service.inspect(deviceIdentifier: identifier) == expected)
        let run = try #require(await service.lastRunDirectory)
        let journal = try FileKernelJournal(directory: run.appendingPathComponent("events"))
        let events = try journal.read()
        #expect(events.contains { if case .decisionRecorded(let text) = $0.payload { return text.contains("sha256=") }; return false })
        #expect(!events.contains { if case .completed = $0.payload { return true }; return false })
        let data = try Data(contentsOf: run.appendingPathComponent("observation.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(DevicePreparationSnapshot.self, from: data).deviceIdentifier == identifier)
    }

    @Test func cancellationAndWrongTargetCannotBecomeSuccess() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RecordedDevicePreparationService(provider: Cancelling(), directory: root)
        await #expect(throws: CancellationError.self) { try await service.inspect(deviceIdentifier: identifier) }
        let wrong = RecordedDevicePreparationService(provider: Stub(value: DevicePreparationSnapshot(deviceIdentifier: UUID().uuidString)), directory: root)
        await #expect(throws: DevicePreparationError.self) { try await wrong.inspect(deviceIdentifier: identifier) }
        await #expect(throws: DevicePreparationError.self) {
            try await LocalDevicePreparationService().inspect(deviceIdentifier: "--device")
        }
    }

    private func complete(at date: Date = .now) -> DevicePreparationSnapshot {
        DevicePreparationSnapshot(deviceIdentifier: identifier, observedAt: date, pairing: .met, tunnel: .met,
            developerMode: .met, ddiServices: .met, passcode: .met)
    }

    private func details(id: String? = nil, version: Int = 3, outcome: String = "success",
                         connection: String = #"{"pairingState":"paired","tunnelState":"connected"}"#,
                         properties: String = #"{"bootState":"booted","developerModeStatus":"enabled","ddiServicesAvailable":true}"#) -> Data {
        Data("""
        {"info":{"jsonVersion":\(version),"commandType":"devicectl.device.info.details","outcome":"\(outcome)"},
        "result":{"identifier":"\(id ?? identifier)","connectionProperties":\(connection),"deviceProperties":\(properties)}}
        """.utf8)
    }

    private func lock(_ properties: String) -> Data {
        Data("""
        {"info":{"jsonVersion":3,"commandType":"devicectl.device.info.lockState","outcome":"success"},
        "result":{"deviceIdentifier":"\(identifier)",\(properties)}}
        """.utf8)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HarnessPreparationTest-\(UUID())")
    }

    private struct Stub: DevicePreparationProviding {
        let value: DevicePreparationSnapshot
        func inspect(deviceIdentifier: String) async throws -> DevicePreparationSnapshot { value }
    }
    private struct Cancelling: DevicePreparationProviding {
        func inspect(deviceIdentifier: String) async throws -> DevicePreparationSnapshot { throw CancellationError() }
    }
}
