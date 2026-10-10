import Foundation

public enum PhysicalDeviceConnection: String, Equatable, Sendable {
    case wired
    case wireless
    case unknown

    public var displayName: String {
        switch self {
        case .wired: "USB接続"
        case .wireless: "ワイヤレス接続"
        case .unknown: "接続中"
        }
    }
}

public struct PhysicalAppleDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let platform: AppleAppPlatform
    public let name: String
    public let modelName: String
    public let osVersion: String
    public let connection: PhysicalDeviceConnection
    public let isPaired: Bool
    public let isDeveloperModeEnabled: Bool
    public let isBooted: Bool
    let deviceIdentifier: String
    let destinationIdentifier: String

    public init(
        id: String,
        platform: AppleAppPlatform = .iPhone,
        name: String,
        modelName: String,
        osVersion: String,
        connection: PhysicalDeviceConnection,
        isPaired: Bool,
        isDeveloperModeEnabled: Bool,
        isBooted: Bool
    ) {
        self.init(
            id: id,
            platform: platform,
            deviceIdentifier: id,
            destinationIdentifier: id,
            name: name,
            modelName: modelName,
            osVersion: osVersion,
            connection: connection,
            isPaired: isPaired,
            isDeveloperModeEnabled: isDeveloperModeEnabled,
            isBooted: isBooted
        )
    }

    init(
        id: String,
        platform: AppleAppPlatform,
        deviceIdentifier: String,
        destinationIdentifier: String,
        name: String,
        modelName: String,
        osVersion: String,
        connection: PhysicalDeviceConnection,
        isPaired: Bool,
        isDeveloperModeEnabled: Bool,
        isBooted: Bool
    ) {
        self.id = id
        self.platform = platform
        self.deviceIdentifier = deviceIdentifier
        self.destinationIdentifier = destinationIdentifier
        self.name = name
        self.modelName = modelName
        self.osVersion = osVersion
        self.connection = connection
        self.isPaired = isPaired
        self.isDeveloperModeEnabled = isDeveloperModeEnabled
        self.isBooted = isBooted
    }
}

public enum XcodeSigningStyle: String, Equatable, Sendable {
    case automatic
    case manual
    case unknown
}

public struct PhysicalDeviceProjectConfiguration: Equatable, Sendable {
    public let containerName: String
    public let scheme: String
    public let productName: String
    public let bundleIdentifier: String?
    public let signingStyle: XcodeSigningStyle
    public let hasDevelopmentTeam: Bool
    public let isIOSApplication: Bool
    let targetBuildDirectory: String?
    let fullProductName: String?

    public init(
        containerName: String,
        scheme: String,
        productName: String,
        bundleIdentifier: String?,
        signingStyle: XcodeSigningStyle,
        hasDevelopmentTeam: Bool,
        isIOSApplication: Bool
    ) {
        self.init(
            containerName: containerName,
            scheme: scheme,
            productName: productName,
            bundleIdentifier: bundleIdentifier,
            signingStyle: signingStyle,
            hasDevelopmentTeam: hasDevelopmentTeam,
            isIOSApplication: isIOSApplication,
            targetBuildDirectory: nil,
            fullProductName: nil
        )
    }

    init(
        containerName: String,
        scheme: String,
        productName: String,
        bundleIdentifier: String?,
        signingStyle: XcodeSigningStyle,
        hasDevelopmentTeam: Bool,
        isIOSApplication: Bool,
        targetBuildDirectory: String?,
        fullProductName: String?
    ) {
        self.containerName = containerName
        self.scheme = scheme
        self.productName = productName
        self.bundleIdentifier = bundleIdentifier
        self.signingStyle = signingStyle
        self.hasDevelopmentTeam = hasDevelopmentTeam
        self.isIOSApplication = isIOSApplication
        self.targetBuildDirectory = targetBuildDirectory
        self.fullProductName = fullProductName
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

public enum PhysicalDeviceSetupRequirement: String, CaseIterable, Equatable, Sendable {
    case verifyDeviceState
    case pairDevice
    case enableDeveloperMode
    case unlockDevice
    case selectAutomaticSigning
    case selectDevelopmentTeam
    case configureBundleIdentifier
    case selectIOSApplication

    public var title: String {
        switch self {
        case .verifyDeviceState: "端末の接続・開発準備状態の再確認"
        case .pairDevice: "Macとのペアリング"
        case .enableDeveloperMode: "Developer Mode"
        case .unlockDevice: "iPhoneの接続状態"
        case .selectAutomaticSigning: "自動署名"
        case .selectDevelopmentTeam: "Personal Team"
        case .configureBundleIdentifier: "Bundle Identifier"
        case .selectIOSApplication: "iOSアプリのscheme"
        }
    }
}

public struct PhysicalDeviceReadiness: Equatable, Sendable {
    public let device: PhysicalAppleDevice
    public let project: PhysicalDeviceProjectConfiguration
    public let requirements: [PhysicalDeviceSetupRequirement]
    public let preparation: DevicePreparationSnapshot?

    public init(
        device: PhysicalAppleDevice,
        project: PhysicalDeviceProjectConfiguration,
        requirements: [PhysicalDeviceSetupRequirement],
        preparation: DevicePreparationSnapshot? = nil
    ) {
        self.device = device
        self.project = project
        self.requirements = requirements
        self.preparation = preparation
    }

    public var canRun: Bool {
        requirements.isEmpty && preparation?.isReady(for: device.deviceIdentifier) == true
    }
}

public enum PhysicalDeviceRunStage: String, Equatable, Sendable {
    case preparing
    case building
    case installing
    case launching

    public var displayName: String {
        switch self {
        case .preparing: "実行前の設定を再確認しています…"
        case .building: "無料の開発用署名でビルドしています…"
        case .installing: "iPhoneへインストールしています…"
        case .launching: "iPhoneでアプリを起動しています…"
        }
    }
}

public struct PhysicalDeviceRunReport: Equatable, Sendable {
    public let deviceName: String
    public let productName: String
    public let bundleIdentifier: String
    public let finishedAt: Date

    public init(
        deviceName: String,
        productName: String,
        bundleIdentifier: String,
        finishedAt: Date = .now
    ) {
        self.deviceName = deviceName
        self.productName = productName
        self.bundleIdentifier = bundleIdentifier
        self.finishedAt = finishedAt
    }
}

public protocol PhysicalDeviceProviding: Sendable {
    func listDevices() async throws -> [PhysicalAppleDevice]
    func inspect(rootPath: String, device: PhysicalAppleDevice) async throws -> PhysicalDeviceReadiness
    func run(
        rootPath: String,
        device: PhysicalAppleDevice,
        onStage: @escaping @Sendable (PhysicalDeviceRunStage) async -> Void
    ) async throws -> PhysicalDeviceRunReport
}
