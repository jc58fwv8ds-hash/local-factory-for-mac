import Foundation

public enum FileCreationReferenceContext {
    public static let maximumDocuments = 8
    public static let maximumTotalCharacters = 24_000
    public static let maximumDocumentCharacters = 6_000

    public static func collect(
        rootPath: String,
        targetPath: String,
        files: [EditableSourceFile],
        editor: any ProjectFileEditing
    ) async -> [EditableSourceDocument] {
        let candidates = prioritizedFiles(targetPath: targetPath, files: files)
        var documents: [EditableSourceDocument] = []
        var remaining = maximumTotalCharacters

        for file in candidates.prefix(maximumDocuments) where remaining > 0 {
            guard let document = try? await editor.load(
                rootPath: rootPath,
                relativePath: file.relativePath
            ) else { continue }
            let limit = min(remaining, maximumDocumentCharacters)
            let content = String(document.content.prefix(limit))
            guard !content.isEmpty else { continue }
            documents.append(
                EditableSourceDocument(
                    relativePath: document.relativePath,
                    content: content
                )
            )
            remaining -= content.count
        }
        return documents
    }

    private static func prioritizedFiles(
        targetPath: String,
        files: [EditableSourceFile]
    ) -> [EditableSourceFile] {
        let targetURL = URL(fileURLWithPath: targetPath)
        let targetDirectory = targetURL.deletingLastPathComponent().path
        let targetExtension = targetURL.pathExtension.lowercased()
        let targetIsTest = targetPath.localizedCaseInsensitiveContains("test")

        return files
            .filter { $0.relativePath != targetPath }
            .filter {
                targetExtension.isEmpty
                    || URL(fileURLWithPath: $0.relativePath).pathExtension.lowercased()
                        == targetExtension
            }
            .sorted { lhs, rhs in
                let lhsScore = score(
                    lhs.relativePath,
                    targetDirectory: targetDirectory,
                    targetIsTest: targetIsTest
                )
                let rhsScore = score(
                    rhs.relativePath,
                    targetDirectory: targetDirectory,
                    targetIsTest: targetIsTest
                )
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                    == .orderedAscending
            }
    }

    private static func score(
        _ path: String,
        targetDirectory: String,
        targetIsTest: Bool
    ) -> Int {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var value = directory == targetDirectory ? 100 : 0
        if targetIsTest && path.localizedCaseInsensitiveContains("test") { value += 20 }
        if path.hasSuffix("App.swift") || path.hasSuffix("Package.swift") { value += 5 }
        return value
    }
}
