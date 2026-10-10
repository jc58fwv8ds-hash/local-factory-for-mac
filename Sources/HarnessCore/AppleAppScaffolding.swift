import Foundation

public struct AppleAppScaffoldRequest: Equatable, Sendable {
    public let parentDirectoryPath: String
    public let productName: String
    public let displayName: String
    public let organizationIdentifier: String

    public init(
        parentDirectoryPath: String,
        productName: String,
        displayName: String,
        organizationIdentifier: String = "local.harness"
    ) {
        self.parentDirectoryPath = parentDirectoryPath
        self.productName = productName
        self.displayName = displayName
        self.organizationIdentifier = organizationIdentifier
    }
}

public struct AppleAppScaffoldResult: Equatable, Sendable {
    public let rootPath: String
    public let projectPath: String
    public let createdRelativePaths: [String]

    public init(rootPath: String, projectPath: String, createdRelativePaths: [String]) {
        self.rootPath = rootPath
        self.projectPath = projectPath
        self.createdRelativePaths = createdRelativePaths
    }
}

public enum AppleAppScaffoldError: LocalizedError, Equatable, Sendable {
    case invalidProductName
    case invalidOrganizationIdentifier
    case parentUnavailable
    case unsafeParent
    case destinationExists
    case creationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidProductName:
            "製品名は英字で始まる3〜40文字の英数字にしてください。"
        case .invalidOrganizationIdentifier:
            "組織IDはドット区切りの英数字で入力してください。"
        case .parentUnavailable:
            "作成先フォルダを確認できません。"
        case .unsafeParent:
            "シンボリックリンク内にはプロジェクトを作成しません。"
        case .destinationExists:
            "同名のファイルまたはフォルダがすでにあります。"
        case .creationFailed:
            "iPhoneアプリの雛形を安全に作成できませんでした。"
        }
    }
}

public protocol AppleAppScaffolding {
    func create(_ request: AppleAppScaffoldRequest) throws -> AppleAppScaffoldResult
}

public struct AppleAppScaffolder: AppleAppScaffolding {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func create(_ request: AppleAppScaffoldRequest) throws -> AppleAppScaffoldResult {
        guard Self.validProductName(request.productName) else {
            throw AppleAppScaffoldError.invalidProductName
        }
        guard Self.validOrganizationIdentifier(request.organizationIdentifier) else {
            throw AppleAppScaffoldError.invalidOrganizationIdentifier
        }

        let parent = URL(fileURLWithPath: request.parentDirectoryPath)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AppleAppScaffoldError.parentUnavailable
        }
        let values = try? parent.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            throw AppleAppScaffoldError.unsafeParent
        }

        let root = parent.appendingPathComponent(request.productName, isDirectory: true)
        guard !fileManager.fileExists(atPath: root.path) else {
            throw AppleAppScaffoldError.destinationExists
        }

        let files = AppleAppStarterFiles.make(for: request)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            for (relativePath, contents) in files {
                let destination = root.appendingPathComponent(relativePath)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try publish(contents, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: root)
            if error is CocoaError {
                throw AppleAppScaffoldError.creationFailed
            }
            throw error
        }

        let projectPath = root
            .appendingPathComponent("\(request.productName).xcodeproj")
            .path
        return AppleAppScaffoldResult(
            rootPath: root.path,
            projectPath: projectPath,
            createdRelativePaths: files.keys.sorted()
        )
    }

    private static func validProductName(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z][A-Za-z0-9]{2,39}$"#,
            options: .regularExpression
        ) != nil
    }

    private func publish(_ contents: String, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".harness-scaffold-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try Data(contents.utf8).write(to: temporary, options: .atomic)
        try fileManager.linkItem(at: temporary, to: destination)
    }

    private static func validOrganizationIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#,
            options: .regularExpression
        ) != nil
    }
}
