import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// The real iPhone (2026-10-18): install the repository's iPhone app with the free signature, read the signature's expiry,
/// then press 入れ直す once. HARNESS_DEVICE_LIVE=<team id> (the copy of the app gets that development team).
@MainActor
struct DeviceInstallLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_DEVICE_LIVE"] != nil))
    func installThenReinstallOnTheConnectedIPhone() async throws {
        let team = ProcessInfo.processInfo.environment["HARNESS_DEVICE_LIVE"]!
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("device-live-\(UUID().uuidString)/HarnessRemote")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repository.appendingPathComponent("HarnessRemote"), to: copy)
        let project = copy.appendingPathComponent("HarnessRemote.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)
            .replacingOccurrences(of: "CODE_SIGN_STYLE = Automatic;", with: "CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = \(team);")
        try text.write(to: project, atomically: true, encoding: .utf8)
        let source = AppleAppSource(projectID: UUID(), projectName: "HarnessRemote", rootPath: copy.path)
        let session = AppleAppLibrarySession(sources: [source], provider: LocalAppleAppLibraryService())
        let records = copy.deletingLastPathComponent().appendingPathComponent("device-installs.json")
        session.installRecordStore = DeviceInstallRecordStore(file: records)
        session.refresh()
        for _ in 0..<600 where session.isBusy { try await Task.sleep(for: .milliseconds(100)) }
        let app = try #require(session.apps.first, "\(session.errorMessage ?? "")")
        let phone = try #require(session.devices.first { $0.platform == .iPhone }, "iPhone が見つかりません")
        session.selectApp(app.id)
        session.selectDevice(phone.id, for: .iPhone)
        session.installSelected()
        for _ in 0..<3000 where session.isBusy { try await Task.sleep(for: .milliseconds(100)) }
        print("1 回目: \(session.statusMessage ?? "") / \(session.errorMessage ?? "問題なし")")
        let first = try #require(session.installRecordStore.load().first)
        print("入れた: \(first.appName) / \(first.deviceName) / 期限 \(String(describing: first.profile?.expiresAt)) / \(first.expiryNote() ?? "")")
        #expect(first.profile != nil)
        try await Task.sleep(for: .seconds(2))
        #expect(session.reinstall(first) == nil)
        for _ in 0..<3000 where session.isBusy { try await Task.sleep(for: .milliseconds(100)) }
        print("2 回目: \(session.errorMessage ?? "問題なし")")
        let second = try #require(session.installRecordStore.load().first)
        print("入れ直した: \(session.statusMessage ?? "") / 期限 \(String(describing: second.profile?.expiresAt))")
        #expect(second.installedAt > first.installedAt)
        try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
    }
}
