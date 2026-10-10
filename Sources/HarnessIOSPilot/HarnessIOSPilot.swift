import Foundation
import HarnessCore
import HarnessExecution

/// A single UI smoke run using an already generated storage implementation. No model regeneration.
@main
struct HarnessIOSPilot {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("iOS pilot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        if args.count == 5, args[1] == "--personal-memory", let deviceID = UUID(uuidString: args[4]) {
            try await PersonalMemoryAcceptance.run(root: URL(fileURLWithPath: args[2]),
                output: URL(fileURLWithPath: args[3]), deviceID: deviceID)
            return
        }
        if args.count == 4, args[1] == "--recover-run" {
            let status = try await ValidationRecoveryService().inspect(
                runDirectory: URL(fileURLWithPath: args[2]), root: URL(fileURLWithPath: args[3])
            )
            print("\(status.rawValue): \(status.explanation)")
            guard status == .verified || status == .legacyVerified else { throw IOSPilotError.validationFailed }
            return
        }
        guard args.count == 5, let deviceID = UUID(uuidString: args[4]) else {
            throw IOSPilotError.usage
        }
        if args[1] == "--inspect-result" {
            try await inspect(bundle: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]), deviceID: deviceID)
            return
        }
        let fixture = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
        let storage = URL(fileURLWithPath: args[2]).standardizedFileURL.resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: args[3]).standardizedFileURL.resolvingSymlinksInPath()
        guard !FileManager.default.fileExists(atPath: output.path) else { throw IOSPilotError.outputExists }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let source = output.appendingPathComponent("source")
        try FileManager.default.copyItem(at: fixture, to: source)
        try FileManager.default.copyItem(at: storage, to: source.appendingPathComponent("App/MemoryStore.swift"))
        let validator = RecordedProjectValidationService(
            provider: XcodeSimulatorValidationService(project: "MemoryPilot.xcodeproj", scheme: "MemoryPilot",
                                                       deviceID: deviceID, artifacts: output.appendingPathComponent("artifacts")),
            directory: output.appendingPathComponent("runs"), requireTests: true, uiAcceptance: acceptance(deviceID)
        )
        print("iPhone Simulator: build → launch → save → terminate → relaunch (one UI test)")
        let report = try await validator.validate(rootPath: source.path)
        for check in report.checks {
            print("\(check.kind.rawValue): \(check.succeeded ? "passed" : "failed") (\(check.duration)s)")
            if !check.succeeded { print(String(check.output.suffix(8_000))) }
        }
        print("Evidence: \(await validator.lastRunDirectory?.path ?? output.path)")
        guard report.succeeded else { throw IOSPilotError.validationFailed }
    }

    static func acceptance(_ deviceID: UUID) -> XcodeUIAcceptance {
        XcodeUIAcceptance(criterion: "画面から保存したメモがアプリ再起動後も残る", deviceID: deviceID,
                          testIdentifiers: ["MemoryPilotUITests/testSavedNoteSurvivesProcessRelaunch()"])
    }

    static func inspect(bundle: URL, output: URL, deviceID: UUID) async throws {
        // An inspection is not a new execution: do not fabricate a fresh Kernel run or source binding.
        guard !FileManager.default.fileExists(atPath: output.path) else { throw IOSPilotError.outputExists }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let exported = try await XcodeResultExportService().export(bundle: bundle, to: output.appendingPathComponent("exported"))
        let archive = ValidationArtifactArchive(directory: output.appendingPathComponent("evidence"))
        let records = try archive.capture(exported.artifacts)
        let criterion = acceptance(deviceID)
        let passed = try archive.satisfies(criterion, records: records)
        let record = IOSPilotInspection(inspectedAt: .now, originalResult: bundle.path,
            uiAcceptance: criterion, passed: passed, artifacts: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: output.appendingPathComponent("inspection.json"), options: .atomic)
        print("Existing result inspection: \(passed ? "passed" : "failed"); \(records.flatMap(\.files).count) files archived.")
        print("No model, build or UI test was rerun. Evidence: \(output.path)")
        guard passed else { throw IOSPilotError.validationFailed }
    }
}

private struct IOSPilotInspection: Encodable {
    let inspectedAt: Date
    let originalResult: String
    let uiAcceptance: XcodeUIAcceptance
    let passed: Bool
    let artifacts: [ValidationArtifactRecord]
}

private enum IOSPilotError: Error {
    case usage // HarnessIOSPilot <ios-fixture> <generated-MemoryStore.swift> <new-output> <simulator-UUID>
    case outputExists, validationFailed
}
