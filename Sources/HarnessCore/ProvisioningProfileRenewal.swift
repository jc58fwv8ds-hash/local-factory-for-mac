import Foundation

/// A free account's development profile renewed before an install (2026-11-11, the user: 「署名期限を更新するため再インストール
/// しても期限あと1日という警告が昨日パーソナルメモリーから消えなかった…無料署名とかの設定もアプリが自動で行うようにして」).
/// Xcode reuses a profile that is still valid, so an install with one day left kept that one day (Personal Memory's profiles,
/// made 11/04, ran out 11/11 00:24 after the 11/10 reinstall). Profiles for the app (and the Watch app inside it) with less
/// than `threshold` left are moved to the Trash first; -allowProvisioningUpdates then makes new seven-day ones.
public enum ProvisioningProfileRenewal {
    public static let threshold: TimeInterval = 3 * 86_400

    public static var profileDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
                home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles")]
    }

    /// Moves the soon-to-expire profiles of `bundleIdentifier` (and identifiers inside it, like `.watchkitapp`) to the Trash.
    /// Returns how many were moved.
    @discardableResult
    public static func retireExpiring(bundleIdentifier: String, now: Date = .now, directories: [URL] = profileDirectories,
                                      trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Int {
        var moved = 0
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "mobileprovision" {
                guard let info = details(of: file), info.appIdentifier.hasSuffix("." + bundleIdentifier)
                        || info.appIdentifier.contains("." + bundleIdentifier + "."),
                      info.expiresAt.timeIntervalSince(now) < threshold else { continue }
                if (try? trash(file)) != nil { moved += 1 }
            }
        }
        return moved
    }

    struct Details { let appIdentifier: String; let expiresAt: Date }

    static func details(of file: URL) -> Details? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["cms", "-D", "-i", file.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // A profile that is a bare property list (not signed) is read as it is.
        return parse(data) ?? (try? Data(contentsOf: file)).flatMap(parse)
    }

    static func parse(_ plist: Data) -> Details? {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let expires = object["ExpirationDate"] as? Date,
              let entitlements = object["Entitlements"] as? [String: Any],
              let identifier = entitlements["application-identifier"] as? String else { return nil }
        return Details(appIdentifier: identifier, expiresAt: expires)
    }
}
