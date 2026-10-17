import Foundation

/// The signing profile built into an app for a device (`embedded.mobileprovision`). With a free (personal team) Apple
/// account it expires about 7 days after it was made, and the app then stops opening until it is installed again
/// (2026-10-12, the user's request: show the days left and prompt a reinstall).
public struct ProvisioningProfile: Equatable, Sendable, Codable {
    public let createdAt: Date
    public let expiresAt: Date
    public let teamName: String

    public init(createdAt: Date, expiresAt: Date, teamName: String) {
        self.createdAt = createdAt; self.expiresAt = expiresAt; self.teamName = teamName
    }

    /// A free account's profile lives about a week; a paid one about a year.
    public var isShortLived: Bool { expiresAt.timeIntervalSince(createdAt) <= 8 * 86_400 }
}

public enum ProvisioningProfileReader {
    /// Decodes `<app>/embedded.mobileprovision` with `security cms -D`; nil when the app has none (a Mac or simulator build).
    public static func read(appURL: URL) -> ProvisioningProfile? {
        let profile = appURL.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: profile.path) else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["cms", "-D", "-i", profile.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? parse(data) : nil
    }

    public static func parse(_ plist: Data) -> ProvisioningProfile? {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let created = object["CreationDate"] as? Date, let expires = object["ExpirationDate"] as? Date else { return nil }
        return ProvisioningProfile(createdAt: created, expiresAt: expires, teamName: object["TeamName"] as? String ?? "")
    }
}

/// One app this Mac installed on a device, with its profile's expiry.
public struct DeviceInstallRecord: Codable, Equatable, Sendable, Identifiable {
    public let appKey: String
    public let appName: String
    public let deviceIdentifier: String
    public let deviceName: String
    public let installedAt: Date
    public let profile: ProvisioningProfile?
    public var id: String { appKey + "|" + deviceIdentifier }

    public init(appKey: String, appName: String, deviceIdentifier: String, deviceName: String, installedAt: Date = .now,
                profile: ProvisioningProfile?) {
        self.appKey = appKey; self.appName = appName; self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName; self.installedAt = installedAt; self.profile = profile
    }

    /// Whole days until the profile expires (0 on its last day, negative once expired); nil without a profile.
    public func daysLeft(now: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let expiry = profile?.expiresAt else { return nil }
        if expiry <= now { return -1 }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiry)).day
    }

    /// The line shown in the app list: nothing for a long-lived profile far from expiry.
    public func expiryNote(now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let profile, let days = daysLeft(now: now, calendar: calendar) else { return nil }
        if days < 0 { return "\(deviceName): 署名の期限が切れました。入れ直すとまた使えます" }
        guard profile.isShortLived || days <= 14 else { return nil }
        return days == 0 ? "\(deviceName): 今日で署名の期限が切れます。入れ直してください" : "\(deviceName): 署名の期限まであと \(days) 日"
    }

    /// Expired or expiring by tomorrow: worth a reminder when the app opens.
    public func needsReinstall(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let days = daysLeft(now: now, calendar: calendar) else { return false }
        return days <= 1
    }
}

/// The records, kept in one JSON file (`~/Library/Application Support/Harness/device-installs.json`); a new install of the
/// same app on the same device replaces the old record.
public struct DeviceInstallRecordStore: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    public static var standard: DeviceInstallRecordStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DeviceInstallRecordStore(file: support.appendingPathComponent("Harness/device-installs.json"))
    }

    public func load() -> [DeviceInstallRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DeviceInstallRecord].self, from: data)) ?? []
    }

    @discardableResult
    public func record(_ record: DeviceInstallRecord) -> [DeviceInstallRecord] {
        var records = load().filter { $0.id != record.id }
        records.append(record)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(records).write(to: file, options: .atomic)
        return records
    }
}
