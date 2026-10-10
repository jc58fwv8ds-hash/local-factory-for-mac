import Foundation

enum SourceRelativePathPolicy {
    static func components(in path: String) -> [Substring]? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path == trimmedPath,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.hasPrefix("/"),
              !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            return nil
        }
        return components
    }

    static func isStructurallySafe(_ path: String) -> Bool {
        components(in: path) != nil
    }

    static func isAllowedCreationPath(_ path: String) -> Bool {
        guard let components = components(in: path),
              !components.contains(where: {
                  SourceFilePolicy.excludedDirectoryNames.contains($0.lowercased())
                      || SourceFilePolicy.isSensitiveFileName(String($0))
              }) else {
            return false
        }
        return SourceFilePolicy.isAllowedFile(URL(fileURLWithPath: path))
    }
}
