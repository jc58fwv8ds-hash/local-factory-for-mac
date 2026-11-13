import Foundation

/// The iPhone's crash reports of one app, copied over with devicectl (2026-11-11). Read only; nothing on the iPhone changes.
public enum DeviceCrashLogs {
    /// Report names of the app newer than `since`, newest first: 「FourteenTranslate-2026-11-11-182458.ips」.
    static func names(in listing: String, appName: String, since: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let prefix = appName + "-"
        return listing.split(separator: "\n").compactMap { line -> (String, Date)? in
            guard let name = line.split(separator: " ").first.map(String.init), name.hasPrefix(prefix), name.hasSuffix(".ips"),
                  !name.hasSuffix(".000.ips") else { return nil }
            let stamp = name.dropFirst(prefix.count).dropLast(4)
            guard let date = formatter.date(from: String(stamp)), date >= since else { return nil }
            return (name, date)
        }
        .sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The newest reports' texts (at most `limit`), or none when the iPhone cannot be reached.
    public static func latest(appName: String, deviceIdentifier: String, since: Date, limit: Int = 3) async -> [String] {
        await Task.detached {
            let listing = run(["devicectl", "device", "info", "files", "--device", deviceIdentifier, "--domain-type", "systemCrashLogs"])
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            return names(in: listing, appName: appName, since: since).prefix(limit).compactMap { name -> String? in
                let destination = folder.appendingPathComponent(name)
                _ = run(["devicectl", "device", "copy", "from", "--device", deviceIdentifier, "--domain-type", "systemCrashLogs",
                         "--source", name, "--destination", destination.path])
                return try? String(contentsOf: destination, encoding: .utf8)
            }
        }.value
    }

    private static func run(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
