import Foundation

/// Material the user gathers for teaching a model something new (2026-11-08, the user: add loading of training material,
/// easy and natural to use). Each set is a folder named for what it teaches (「浴衣」, 「動き」), holding copies of the
/// pictures and videos dropped on it, so moving or deleting the originals changes nothing.
public struct TrainingMaterials: Sendable {
    public static let pictureTypes = ["png", "jpg", "jpeg", "heic", "webp"]
    public static let videoTypes = ["mp4", "mov", "m4v"]

    public let root: URL

    public init(root: URL) { self.root = root }

    /// The app's own place for it: ~/Library/Application Support/Harness/Training.
    public static var standard: TrainingMaterials {
        TrainingMaterials(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Harness/Training"))
    }

    public struct Set: Identifiable, Equatable, Sendable {
        public var name: String
        public var files: [URL]
        public var id: String { name }
        public var pictures: Int { files.filter { TrainingMaterials.pictureTypes.contains($0.pathExtension.lowercased()) }.count }
        public var videos: Int { files.count - pictures }
    }

    public func sets() -> [Set] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix(".") }
            .map { Set(name: $0.lastPathComponent, files: files(in: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A new, empty set; a name already used gets a number.
    @discardableResult
    public func addSet(named name: String) throws -> String {
        let base = Self.cleanName(name)
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(number)"; number += 1
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(candidate), withIntermediateDirectories: true)
        return candidate
    }

    /// Copies the pictures and videos among `items` into the set; a folder brings what it holds, at any depth. Returns how
    /// many were added; other files are left out.
    @discardableResult
    public func add(_ items: [URL], to set: String) throws -> Int {
        let folder = root.appendingPathComponent(set)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var added = 0
        for source in items.flatMap(Self.media(in:)) {
            var target = folder.appendingPathComponent(source.lastPathComponent)
            var number = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) \(number).\(source.pathExtension)")
                number += 1
            }
            try FileManager.default.copyItem(at: source, to: target)
            added += 1
        }
        return added
    }

    /// Moves one file of a set to the Trash (the user empties it).
    public func remove(_ file: URL) throws {
        guard file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else { return }
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
    }

    /// Moves a whole set to the Trash.
    public func removeSet(_ name: String) throws {
        let folder = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }

    static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "・")
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? "新しい素材" : trimmed
    }

    static func isMedia(_ url: URL) -> Bool {
        let type = url.pathExtension.lowercased()
        return pictureTypes.contains(type) || videoTypes.contains(type)
    }

    static func media(in url: URL) -> [URL] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return [] }
        guard isFolder.boolValue else { return isMedia(url) ? [url] : [] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (walker?.allObjects as? [URL] ?? []).filter(isMedia).sorted { $0.path < $1.path }
    }

    private func files(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter(Self.isMedia).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
