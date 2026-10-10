import Foundation

public actor ProjectFileEditor: ProjectFileEditing {
    public static let maximumFileBytes = 512_000

    private let fileManager: FileManager
    private let maximumEntries: Int
    private let maximumListedFiles: Int

    public init(
        fileManager: FileManager = .default,
        maximumEntries: Int = 4_000,
        maximumListedFiles: Int = 500
    ) {
        self.fileManager = fileManager
        self.maximumEntries = max(1, maximumEntries)
        self.maximumListedFiles = max(1, maximumListedFiles)
    }

    public func editableFiles(rootPath: String) throws -> [EditableSourceFile] {
        let rootURL = try validatedRootURL(rootPath)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ProjectFileEditError.sourceNotDirectory
        }

        var files: [EditableSourceFile] = []
        var visited = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            guard visited <= maximumEntries else { break }

            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ) else { continue }

            if values.isDirectory == true {
                if SourceFilePolicy.excludedDirectoryNames.contains(
                    url.lastPathComponent.lowercased()
                ) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let byteCount = values.fileSize ?? 0
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  byteCount <= Self.maximumFileBytes,
                  SourceFilePolicy.isAllowedFile(url),
                  !SourceFilePolicy.isSensitiveFileName(url.lastPathComponent) else { continue }

            files.append(
                EditableSourceFile(
                    relativePath: SourceFilePolicy.relativePath(for: url, rootURL: rootURL),
                    byteCount: byteCount
                )
            )
            if files.count >= maximumListedFiles { break }
        }

        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    public func load(
        rootPath: String,
        relativePath: String
    ) throws -> EditableSourceDocument {
        let url = try validatedFileURL(rootPath: rootPath, relativePath: relativePath)
        return EditableSourceDocument(
            relativePath: relativePath,
            content: try readContent(from: url)
        )
    }

    public func makeProposal(
        document: EditableSourceDocument,
        proposedContent: String
    ) throws -> FileChangeProposal {
        try validateProposedContent(proposedContent)
        return try FileLineDiff.proposal(
            document: document,
            proposedContent: proposedContent
        )
    }

    public func makeCreationProposal(
        rootPath: String,
        relativePath: String,
        proposedContent: String
    ) throws -> FileChangeProposal {
        _ = try validatedCreationURL(rootPath: rootPath, relativePath: relativePath)
        try validateProposedContent(proposedContent)
        return try FileLineDiff.proposal(
            document: EditableSourceDocument(relativePath: relativePath, content: ""),
            proposedContent: proposedContent,
            operation: .creation
        )
    }

    public func validateCreationPath(rootPath: String, relativePath: String) throws {
        _ = try validatedCreationURL(rootPath: rootPath, relativePath: relativePath)
    }

    public func apply(rootPath: String, proposal: FileChangeProposal) throws {
        try validateProposedContent(proposal.proposedContent)
        if proposal.operation == .creation {
            let url = try validatedCreationURL(
                rootPath: rootPath,
                relativePath: proposal.relativePath
            )
            try writeNew(proposal.proposedContent, to: url)
            return
        }
        let url = try validatedFileURL(
            rootPath: rootPath,
            relativePath: proposal.relativePath
        )
        guard try readContent(from: url) == proposal.originalContent else {
            throw ProjectFileEditError.changedSinceReview
        }
        try write(proposal.proposedContent, to: url)
    }

    public func revert(rootPath: String, proposal: FileChangeProposal) throws {
        let url = try validatedFileURL(
            rootPath: rootPath,
            relativePath: proposal.relativePath
        )
        guard try readContent(from: url) == proposal.proposedContent else {
            throw ProjectFileEditError.changedSinceReview
        }
        if proposal.operation == .creation {
            try fileManager.removeItem(at: url)
            return
        }
        try write(proposal.originalContent, to: url)
    }

    private func validatedRootURL(_ path: String) throws -> URL {
        let rootURL = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw ProjectFileEditError.sourceMissing
        }
        guard isDirectory.boolValue else {
            throw ProjectFileEditError.sourceNotDirectory
        }
        return rootURL
    }

    private func validatedFileURL(rootPath: String, relativePath: String) throws -> URL {
        let rootURL = try validatedRootURL(rootPath)
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw ProjectFileEditError.invalidRelativePath
        }

        let unresolvedURL = rootURL.appendingPathComponent(relativePath)
        guard let values = try? unresolvedURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ProjectFileEditError.fileNotEditable
        }

        let resolvedURL = unresolvedURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard resolvedURL.path.hasPrefix(rootPrefix),
              SourceFilePolicy.isAllowedFile(resolvedURL),
              !SourceFilePolicy.isSensitiveFileName(resolvedURL.lastPathComponent) else {
            throw ProjectFileEditError.invalidRelativePath
        }
        return resolvedURL
    }

    private func validatedCreationURL(rootPath: String, relativePath: String) throws -> URL {
        let rootURL = try validatedRootURL(rootPath)
        guard SourceRelativePathPolicy.isAllowedCreationPath(relativePath) else {
            throw ProjectFileEditError.invalidRelativePath
        }

        let targetURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard targetURL.path.hasPrefix(rootPrefix),
              SourceFilePolicy.isAllowedFile(targetURL) else {
            throw ProjectFileEditError.invalidRelativePath
        }
        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw ProjectFileEditError.fileAlreadyExists
        }
        if let values = try? targetURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw ProjectFileEditError.fileAlreadyExists
        }

        let parentURL = targetURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProjectFileEditError.parentDirectoryMissing
        }
        let resolvedParent = parentURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedParent.path == parentURL.path,
              resolvedParent.path == rootURL.path || resolvedParent.path.hasPrefix(rootPrefix) else {
            throw ProjectFileEditError.invalidRelativePath
        }
        return targetURL
    }

    private func readContent(from url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= Self.maximumFileBytes else {
            throw ProjectFileEditError.fileTooLarge(maximumBytes: Self.maximumFileBytes)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.contains(0), let content = String(data: data, encoding: .utf8) else {
            throw ProjectFileEditError.unreadableText
        }
        return content
    }

    private func validateProposedContent(_ content: String) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectFileEditError.emptyContent
        }
        guard content.lengthOfBytes(using: .utf8) <= Self.maximumFileBytes else {
            throw ProjectFileEditError.fileTooLarge(maximumBytes: Self.maximumFileBytes)
        }
    }

    private func write(_ content: String, to url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        try Data(content.utf8).write(to: url, options: .atomic)
        if let permissions = attributes[.posixPermissions] {
            try? fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        }
    }

    private func writeNew(_ content: String, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".harness-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Data(content.utf8).write(to: temporaryURL, options: .atomic)
        do {
            try fileManager.linkItem(at: temporaryURL, to: url)
        } catch {
            if fileManager.fileExists(atPath: url.path) {
                throw ProjectFileEditError.fileAlreadyExists
            }
            throw error
        }
    }
}
