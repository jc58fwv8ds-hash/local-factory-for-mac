import Foundation

public enum XcodeProjectSelection {
    public static func preferredScheme(
        from schemes: [String],
        container: XcodeProjectContainer
    ) -> String? {
        let baseName = URL(fileURLWithPath: container.name)
            .deletingPathExtension()
            .lastPathComponent
        return schemes.first { $0.caseInsensitiveCompare(baseName) == .orderedSame }
            ?? schemes.first
    }
}
