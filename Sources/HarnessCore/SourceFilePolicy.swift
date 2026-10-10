import Foundation

enum SourceFilePolicy {
    static let excludedDirectoryNames: Set<String> = [
        ".build", "build", "deriveddata", "dist", "node_modules", "pods",
        "vendor", "xcuserdata", "coverage", ".git"
    ]

    static let preferredFileNames: Set<String> = [
        "readme", "readme.md", "package.swift", "package.json", "pyproject.toml",
        "requirements.txt", "cargo.toml", "go.mod", "project.yml", "project.yaml"
    ]

    static let allowedExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "cs", "java", "kt", "kts",
        "js", "jsx", "ts", "tsx", "py", "rb", "rs", "go", "php", "html", "css",
        "scss", "sql", "sh", "zsh", "md", "toml", "yaml", "yml", "json"
    ]

    static func isAllowedFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if preferredFileNames.contains(name) { return true }
        if name.hasSuffix(".lock") || name == "package-lock.json" { return false }
        return allowedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSensitiveFileName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let sensitiveTokens = ["secret", "credential", "private_key", "id_rsa", "id_dsa"]
        return sensitiveTokens.contains(where: lowered.contains)
            || lowered.hasSuffix(".pem")
            || lowered.hasSuffix(".p12")
            || lowered.hasSuffix(".key")
            || lowered.hasSuffix(".keystore")
    }

    static func priority(for url: URL) -> Int {
        let name = url.lastPathComponent.lowercased()
        if preferredFileNames.contains(name) { return 0 }
        switch url.pathExtension.lowercased() {
        case "swift", "m", "mm", "h", "c", "cc", "cpp", "cs", "java", "kt", "kts",
             "js", "jsx", "ts", "tsx", "py", "rb", "rs", "go", "php":
            return 1
        default:
            return 2
        }
    }

    static func relativePath(for url: URL, rootURL: URL) -> String {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard resolvedURL.path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(resolvedURL.path.dropFirst(rootPath.count))
    }
}
