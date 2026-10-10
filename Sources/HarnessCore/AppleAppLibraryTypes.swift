import Foundation

public enum AppleAppPlatform: String, CaseIterable, Equatable, Hashable, Sendable {
    case iPhone
    case appleWatch

    public var displayName: String {
        switch self {
        case .iPhone: "iPhone"
        case .appleWatch: "Apple Watch"
        }
    }
}

public struct AppleAppSource: Equatable, Sendable {
    public let projectID: UUID
    public let projectName: String
    public let rootPath: String

    public init(projectID: UUID, projectName: String, rootPath: String) {
        self.projectID = projectID
        self.projectName = projectName
        self.rootPath = rootPath
    }
}

public enum WatchAppRelationship: String, Equatable, Sendable {
    case independent
    case requiresCompanion
    case watchOnly
}

public struct AppleAppBuildConfiguration: Equatable, Sendable {
    public let platform: AppleAppPlatform
    public let scheme: String
    public let productName: String
    public let bundleIdentifier: String?
    public let signingStyle: XcodeSigningStyle
    public let hasDevelopmentTeam: Bool
    public let watchRelationship: WatchAppRelationship?
    let companionBundleIdentifier: String?
    let targetBuildDirectory: String?
    let fullProductName: String?
    let appIconName: String?

    public init(
        platform: AppleAppPlatform,
        scheme: String,
        productName: String,
        bundleIdentifier: String?,
        signingStyle: XcodeSigningStyle,
        hasDevelopmentTeam: Bool,
        watchRelationship: WatchAppRelationship? = nil
    ) {
        self.init(
            platform: platform,
            scheme: scheme,
            productName: productName,
            bundleIdentifier: bundleIdentifier,
            signingStyle: signingStyle,
            hasDevelopmentTeam: hasDevelopmentTeam,
            watchRelationship: watchRelationship,
            companionBundleIdentifier: nil,
            targetBuildDirectory: nil,
            fullProductName: nil,
            appIconName: nil
        )
    }

    init(
        platform: AppleAppPlatform,
        scheme: String,
        productName: String,
        bundleIdentifier: String?,
        signingStyle: XcodeSigningStyle,
        hasDevelopmentTeam: Bool,
        watchRelationship: WatchAppRelationship?,
        companionBundleIdentifier: String?,
        targetBuildDirectory: String?,
        fullProductName: String?,
        appIconName: String?
    ) {
        self.platform = platform
        self.scheme = scheme
        self.productName = productName
        self.bundleIdentifier = bundleIdentifier
        self.signingStyle = signingStyle
        self.hasDevelopmentTeam = hasDevelopmentTeam
        self.watchRelationship = watchRelationship
        self.companionBundleIdentifier = companionBundleIdentifier
        self.targetBuildDirectory = targetBuildDirectory
        self.fullProductName = fullProductName
        self.appIconName = appIconName
    }

    public var hasUsableBundleIdentifier: Bool {
        guard let bundleIdentifier else { return false }
        let value = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 255,
              value.contains("."),
              !value.contains("$("),
              !value.lowercased().contains("your.bundle") else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
        }
    }
}

public struct InstallableAppleApp: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: AppleAppSource
    public let container: XcodeProjectContainer
    public let scheme: String
    public let displayName: String
    public let configurations: [AppleAppBuildConfiguration]
    public let iconData: Data?

    public init(
        id: String,
        source: AppleAppSource,
        container: XcodeProjectContainer,
        scheme: String,
        displayName: String,
        configurations: [AppleAppBuildConfiguration],
        iconData: Data? = nil
    ) {
        self.id = id
        self.source = source
        self.container = container
        self.scheme = scheme
        self.displayName = displayName
        self.configurations = configurations
        self.iconData = iconData
    }

    public var supportedPlatforms: [AppleAppPlatform] {
        AppleAppPlatform.allCases.filter { configuration(for: $0) != nil }
    }

    public var needsSigningSetup: Bool {
        configurations.contains {
            $0.signingStyle != .automatic
                || !$0.hasDevelopmentTeam
                || !$0.hasUsableBundleIdentifier
        }
    }

    public func configuration(for platform: AppleAppPlatform) -> AppleAppBuildConfiguration? {
        configurations.first { $0.platform == platform }
    }
}

public enum AppleAppInstallStage: String, Equatable, Sendable {
    case preparing
    case building
    case installing
    case launching

    public func displayName(for platform: AppleAppPlatform) -> String {
        switch self {
        case .preparing: "実行条件を確認しています…"
        case .building: "無料の開発用署名でビルドしています…"
        case .installing: "\(platform.displayName)へインストールしています…"
        case .launching: "\(platform.displayName)で起動しています…"
        }
    }
}

public struct AppleAppInstallReport: Equatable, Sendable {
    public let appName: String
    public let deviceName: String
    public let platform: AppleAppPlatform
    public let finishedAt: Date

    public init(
        appName: String,
        deviceName: String,
        platform: AppleAppPlatform,
        finishedAt: Date = .now
    ) {
        self.appName = appName
        self.deviceName = deviceName
        self.platform = platform
        self.finishedAt = finishedAt
    }
}

public protocol AppleAppLibraryProviding: Sendable {
    func discoverApps(in sources: [AppleAppSource]) async throws -> [InstallableAppleApp]
    func listDevices() async throws -> [PhysicalAppleDevice]
    func install(
        _ app: InstallableAppleApp,
        on device: PhysicalAppleDevice,
        onStage: @escaping @Sendable (AppleAppInstallStage) async -> Void
    ) async throws -> AppleAppInstallReport
}
