import Foundation
import HarnessCore

/// Runs DeveloperDataJanitor at launch and every 6 hours, in the background (2026-11-25). What it moved is appended to
/// developer-data-sweeps.log in Harness's Application Support folder; simulator devices whose runtime is gone are deleted
/// with `simctl delete unavailable` (working devices stay).
enum DeveloperDataSweeper {
    static var log: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness/developer-data-sweeps.log")
    }

    static func start() {
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                // A minute after launch, so the first window and any model start are not slowed.
                try? await Task.sleep(for: .seconds(60))
                sweepOnce()
                try? await Task.sleep(for: .seconds(6 * 3_600 - 60))
            }
        }
    }

    static func sweepOnce() {
        let report = DeveloperDataJanitor().sweep()
        let unavailable = Process()
        unavailable.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        unavailable.arguments = ["simctl", "delete", "unavailable"]
        unavailable.standardOutput = FileHandle.nullDevice; unavailable.standardError = FileHandle.nullDevice
        if (try? unavailable.run()) != nil { unavailable.waitUntilExit() }
        guard !report.moved.isEmpty else { return }
        let line = "\(Date().formatted(.iso8601)) \(report.moved.count) 件・\(ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file)): "
            + report.moved.joined(separator: ", ") + "\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: log, atomically: true, encoding: .utf8)
        }
    }
}
