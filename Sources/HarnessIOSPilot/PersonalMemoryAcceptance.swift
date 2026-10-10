import Foundation
import HarnessCore
import HarnessExecution

/// Explicit single acceptance run on the real generated project, not the old storage fixture.
enum PersonalMemoryAcceptance {
    static func run(root: URL, output: URL, deviceID: UUID) async throws {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let output = output.standardizedFileURL.resolvingSymlinksInPath()
        guard output.path != root.path, !output.path.hasPrefix(root.path + "/"),
              !FileManager.default.fileExists(atPath: output.path) else { throw AcceptanceError.outputExists }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let service = RecordedProjectValidationService(
            provider: XcodeSimulatorValidationService(project: "PersonalMemory.xcodeproj",
                scheme: "PersonalMemoryAcceptance", deviceID: deviceID,
                artifacts: output.appendingPathComponent("artifacts")),
            directory: output.appendingPathComponent("runs"), requireTests: true,
            uiAcceptance: .init(criterion: "画面から入力・保存し、アプリ終了後の再起動で同じ記録を表示できる",
                deviceID: deviceID, testIdentifiers: ["PersonalMemoryUITests/testInputSaveAndProcessRelaunch()"]))
        print("Personal Memory: one UI acceptance run; existing app data is preserved.")
        let report = try await service.validate(rootPath: root.path)
        for check in report.checks {
            print("\(check.kind.rawValue): \(check.succeeded ? "passed" : "failed") (\(check.duration)s)")
            if !check.succeeded { print(String(check.output.suffix(6_000))) }
        }
        let data = try JSONEncoder().encode(report)
        try data.write(to: output.appendingPathComponent("report.json"), options: .atomic)
        print("Evidence: \(await service.lastRunDirectory?.path ?? output.path)")
        guard report.succeeded else { throw AcceptanceError.failed }
    }

    private enum AcceptanceError: Error { case outputExists, failed }
}
