import Foundation

struct AppleAppIconLoader: Sendable {
    private let maximumEntries = 2_000
    private let maximumIconBytes = 10_000_000

    func iconData(rootURL: URL, iconNames: [String]) -> Data? {
        let names = Set(iconNames.filter { !$0.isEmpty }.map { "\($0).appiconset" })
        guard !names.isEmpty,
              let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return nil }

        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > maximumEntries { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true,
               SourceFilePolicy.excludedDirectoryNames.contains(url.lastPathComponent.lowercased()) {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isDirectory == true, names.contains(url.lastPathComponent) else { continue }
            return data(from: url, rootURL: rootURL)
        }
        return nil
    }

    private func data(from iconSetURL: URL, rootURL: URL) -> Data? {
        let contentsURL = iconSetURL.appendingPathComponent("Contents.json")
        guard let manifestData = try? Data(contentsOf: contentsURL),
              manifestData.count <= 1_000_000,
              let manifest = try? JSONDecoder().decode(AppIconManifest.self, from: manifestData) else {
            return nil
        }
        let filenames = manifest.images.compactMap(\.filename)
        for filename in filenames.reversed() {
            guard isSafeFilename(filename) else { continue }
            let candidate = iconSetURL.appendingPathComponent(filename)
                .standardizedFileURL.resolvingSymlinksInPath()
            let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.path.hasPrefix(root.path + "/"),
                  let data = try? Data(contentsOf: candidate, options: .mappedIfSafe),
                  !data.isEmpty,
                  data.count <= maximumIconBytes else { continue }
            return data
        }
        return nil
    }

    private func isSafeFilename(_ value: String) -> Bool {
        guard value.count <= 255,
              !value.contains("/"),
              !value.contains("\\"),
              value != ".",
              value != ".." else { return false }
        return ["png", "jpg", "jpeg"].contains(
            URL(fileURLWithPath: value).pathExtension.lowercased()
        )
    }
}

private struct AppIconManifest: Decodable {
    let images: [AppIconManifestImage]
}

private struct AppIconManifestImage: Decodable {
    let filename: String?
}
