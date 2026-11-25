import Foundation

/// Keeps Xcode's developer data from piling up while Local Factory builds apps (2026-11-25, the user: ~/Library/Developer
/// had grown to 55 GB from DerivedData, simulator devices and DeviceSupport; they cleaned it by hand and asked that Factory
/// not let it build up again without breaking Factory or the apps it works on, such as 14Translate).
///
/// What it touches, and only that:
/// - Xcode's own DerivedData (`~/Library/Developer/Xcode/DerivedData`): a folder for a Factory project (its workspace is
///   under Harness/Projects) unused for a day, any other unused for 14 days. Xcode rebuilds it when needed.
/// - DeviceSupport (`~/Library/Developer/Xcode/<platform> DeviceSupport`): per platform the newest version and any used in
///   the last 30 days stay; older ones go. Xcode copies them again from a device when one with that version is connected.
/// - What Factory's own checks left in the temporary folder when the app stopped mid-build (`HarnessDerivedData-*`,
///   `HarnessDeviceBuild-*`, and the like) after a day.
/// - Simulator devices whose runtime is gone (`simctl delete unavailable`); working devices are never deleted.
/// Folders outside Factory's own go to the Trash (the user empties it); nothing is removed while it was used in the
/// last hour.
public struct DeveloperDataJanitor: Sendable {
    public struct Report: Equatable, Sendable {
        public var moved: [String] = []
        public var bytes: Int64 = 0
    }

    let home: URL
    let temporary: URL
    let now: Date
    let trash: @Sendable (URL) throws -> Void

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                temporary: URL = FileManager.default.temporaryDirectory,
                now: Date = Date(),
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.home = home; self.temporary = temporary; self.now = now; self.trash = trash
    }

    static let day: TimeInterval = 86_400
    static let temporaryPrefixes = ["HarnessDerivedData-", "HarnessDeviceBuild-", "HarnessAppInstall-", "HarnessSimulator-"]

    /// Runs every sweep; returns what was moved.
    public func sweep() -> Report {
        var report = Report()
        sweepDerivedData(&report)
        sweepDeviceSupport(&report)
        sweepTemporary(&report)
        return report
    }

    func sweepDerivedData(_ report: inout Report) {
        let folder = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let projects = home.appendingPathComponent("Library/Application Support/Harness/Projects").path
        for item in children(of: folder) where item.lastPathComponent != "ModuleCache.noindex" {
            let workspace = Self.workspacePath(of: item) ?? ""
            let age: TimeInterval = workspace.hasPrefix(projects) ? Self.day : 14 * Self.day
            move(item, ifUnusedFor: age, &report)
        }
    }

    func sweepDeviceSupport(_ report: inout Report) {
        let xcode = home.appendingPathComponent("Library/Developer/Xcode")
        for platform in children(of: xcode) where platform.lastPathComponent.hasSuffix(" DeviceSupport") {
            let versions = children(of: platform).sorted { Self.lastUsed($0) > Self.lastUsed($1) }
            let newest = versions.max { Self.versionKey($0.lastPathComponent).lexicographicallyPrecedes(Self.versionKey($1.lastPathComponent)) }
            for version in versions where version != newest {
                move(version, ifUnusedFor: 30 * Self.day, &report)
            }
        }
    }

    func sweepTemporary(_ report: inout Report) {
        for item in children(of: temporary) where Self.temporaryPrefixes.contains(where: item.lastPathComponent.hasPrefix) {
            guard now.timeIntervalSince(Self.lastUsed(item)) > Self.day else { continue }
            let size = Self.size(of: item)
            // Factory's own leftovers: removed outright, they never were the user's.
            if (try? FileManager.default.removeItem(at: item)) != nil {
                report.moved.append(item.lastPathComponent); report.bytes += size
            }
        }
    }

    private func move(_ item: URL, ifUnusedFor age: TimeInterval, _ report: inout Report) {
        guard now.timeIntervalSince(Self.lastUsed(item)) > max(age, 3_600) else { return }
        let size = Self.size(of: item)
        if (try? trash(item)) != nil { report.moved.append(item.path); report.bytes += size }
    }

    private func children(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// The workspace a DerivedData folder was built for, from the info.plist Xcode writes in it.
    static func workspacePath(of folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["WorkspacePath"] as? String
    }

    /// The latest change to the folder or the items right inside it (a build touches its Build and Logs folders).
    static func lastUsed(_ url: URL) -> Date {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        var latest = (try? url.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
        for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? [] {
            if let date = try? child.resourceValues(forKeys: keys).contentModificationDate, date > latest { latest = date }
        }
        return latest
    }

    /// "18.2 (22C150)" → [18, 2]; names without numbers sort first.
    static func versionKey(_ name: String) -> [Int] {
        let head = name.split(separator: " ").first.map(String.init) ?? name
        return head.split(separator: ".").compactMap { Int($0) }
    }

    public static func size(of url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
