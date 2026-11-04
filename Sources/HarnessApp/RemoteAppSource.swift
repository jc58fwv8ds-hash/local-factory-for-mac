import Foundation
import HarnessCore

/// The iPhone app for the agent link (HarnessRemote) as an app of the Apps screen (2026-11-02, the user: install it from
/// Local Factory). Its Xcode project comes inside this app (Resources/HarnessRemote, put there by
/// scripts/package_release.sh) or, in a development build, from the checkout; it is copied to Application Support so the
/// installer builds it from a folder that does not move with the app.
enum RemoteAppSource {
    static let projectID = UUID(uuidString: "6C0C5E1A-7A51-4F0E-9D7B-0A6E1F2B3C4D")!
    static let name = "Local Factory Remote(iPhone)"

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalFactory/HarnessRemote")
    }

    /// The source for the Apps screen, or nothing when the project is not with this app.
    static var sources: [AppleAppSource] {
        prepared ? [AppleAppSource(projectID: projectID, projectName: name, rootPath: folder.path)] : []
    }

    private static let prepared: Bool = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("HarnessRemote")
        let checkout = OrchestratedRunSettings().candidatePath.map { URL(fileURLWithPath: $0).appendingPathComponent("HarnessRemote") }
        let manager = FileManager.default
        guard let source = [bundled, checkout].compactMap({ $0 }).first(where: {
            manager.fileExists(atPath: $0.appendingPathComponent("HarnessRemote.xcodeproj").path)
        }) else { return manager.fileExists(atPath: folder.appendingPathComponent("HarnessRemote.xcodeproj").path) }
        do {
            try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = folder.deletingLastPathComponent().appendingPathComponent("HarnessRemote-new")
            try? manager.removeItem(at: staged)
            try manager.copyItem(at: source, to: staged)
            signWithThisMacsTeam(staged.appendingPathComponent("HarnessRemote.xcodeproj/project.pbxproj"))
            if manager.fileExists(atPath: folder.path) {
                _ = try manager.replaceItemAt(folder, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: folder)
            }
            return true
        } catch {
            return manager.fileExists(atPath: folder.appendingPathComponent("HarnessRemote.xcodeproj").path)
        }
    }()

    /// The public project names no team; the copy here gets the team of this Mac's development certificate (its OU), so
    /// the Apps screen can sign it without Xcode. Nothing changes when there is no such certificate.
    private static func signWithThisMacsTeam(_ project: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/usr/bin/security find-certificate -c 'Apple Development' -p | /usr/bin/openssl x509 -noout -subject"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        let subject = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let range = subject.range(of: #"OU\s*=\s*[A-Z0-9]{10}"#, options: .regularExpression),
              let text = try? String(contentsOf: project, encoding: .utf8) else { return }
        let team = subject[range].suffix(10)
        let signed = text.replacingOccurrences(of: "CODE_SIGN_STYLE = Automatic;", with: "CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = \(team);")
        try? signed.write(to: project, atomically: true, encoding: .utf8)
    }
}
