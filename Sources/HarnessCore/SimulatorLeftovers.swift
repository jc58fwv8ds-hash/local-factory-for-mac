import Foundation

/// Apps the Simulator keeps after each reinstall, moved to the Trash before a check (2026-11-17: every test run put
/// 14Translate on the Simulator again, the Simulator kept each old copy with its 573 MB translation model, fourteen of
/// them filled the last 7.9 GB of the disk, and the next build failed with 「No space left on device」).
/// Moved, never deleted: the person empties the Trash.
public enum SimulatorLeftovers {
    public static let minimumBytes: Int64 = 1 << 30

    /// The leftover folders of every Simulator, and their total size.
    public static func find(devicesRoot: URL = defaultDevicesRoot) -> (folders: [URL], bytes: Int64) {
        let fm = FileManager.default
        let devices = (try? fm.contentsOfDirectory(at: devicesRoot, includingPropertiesForKeys: nil)) ?? []
        var folders: [URL] = []
        var bytes: Int64 = 0
        for device in devices {
            let dead = device.appendingPathComponent("data/Library/Caches/com.apple.containermanagerd/Dead")
            for item in (try? fm.contentsOfDirectory(at: dead, includingPropertiesForKeys: nil)) ?? [] {
                folders.append(item)
                bytes += size(of: item)
            }
        }
        return (folders, bytes)
    }

    /// Moves them to the Trash when they add up to a gigabyte or more; the bytes moved, or 0.
    @discardableResult
    public static func moveToTrash(devicesRoot: URL = defaultDevicesRoot, minimum: Int64 = minimumBytes,
                                   trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Int64 {
        let found = find(devicesRoot: devicesRoot)
        guard found.bytes >= minimum else { return 0 }
        var moved: Int64 = 0
        for folder in found.folders {
            let bytes = size(of: folder)
            if (try? trash(folder)) != nil { moved += bytes }
        }
        return moved
    }

    /// A line for the chat, or nil when nothing was moved.
    public static func note(movedBytes: Int64) -> String? {
        guard movedBytes > 0 else { return nil }
        let gigabytes = String(format: "%.1f", Double(movedBytes) / Double(1 << 30))
        return "シミュレータに残っていた古いアプリ(\(gigabytes) GB)をゴミ箱に移しました。ゴミ箱を空にすると、その分ディスクが空きます。"
    }

    public static var defaultDevicesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
    }

    static func size(of url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
