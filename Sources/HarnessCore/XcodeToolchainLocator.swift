import Foundation

struct XcodeToolchainLocator: Sendable {
    func standardDeveloperDirectory() -> URL? {
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let applicationURLs = (try? FileManager.default.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return applicationURLs
            .filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
            .sorted(by: Self.isPreferred)
            .map { $0.appendingPathComponent("Contents/Developer", isDirectory: true) }
            .first(where: isUsableDeveloperDirectory)
    }

    private func isUsableDeveloperDirectory(_ url: URL) -> Bool {
        let executable = url.appendingPathComponent("usr/bin/xcodebuild").path
        return FileManager.default.isExecutableFile(atPath: executable)
    }

    private static func isPreferred(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.lastPathComponent == "Xcode.app" { return true }
        if rhs.lastPathComponent == "Xcode.app" { return false }
        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
            == .orderedAscending
    }
}
