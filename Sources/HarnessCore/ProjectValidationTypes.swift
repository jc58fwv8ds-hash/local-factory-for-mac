import Foundation

public enum ProjectValidationKind: String, Codable, CaseIterable, Sendable {
    case build
    case test
    case xcodeBuild
    case xcodeTest

    public var displayName: String {
        switch self {
        case .build: "Swift Build"
        case .test: "Swift Test"
        case .xcodeBuild: "Xcode Build"
        case .xcodeTest: "Xcode Test"
        }
    }
}

public enum ProjectValidationSystem: String, Codable, Sendable {
    case swiftPackage
    case xcode
}

public struct ProjectValidationSupport: Equatable, Sendable {
    public let system: ProjectValidationSystem
    public let containerName: String?

    public init(system: ProjectValidationSystem, containerName: String? = nil) {
        self.system = system
        self.containerName = containerName
    }

    public var headerDescription: String {
        switch system {
        case .swiftPackage:
            "Swift Packageを固定された検証コマンドで確認します。"
        case .xcode:
            "XcodeプロジェクトのschemeをDebug構成で確認します。"
        }
    }

    public var commandSummary: String {
        switch system {
        case .swiftPackage: "swift build  →  成功時のみ swift test"
        case .xcode: "xcodebuild -list  →  Debug build  →  テストがあればSimulatorで実行"
        }
    }

    public var startButtonTitle: String {
        switch system {
        case .swiftPackage: "ビルドとテストを実行"
        case .xcode: "Xcodeのビルドとテストを実行"
        }
    }

    public var automaticDescription: String {
        switch system {
        case .swiftPackage: "Swift BuildとSwift Testを実行します。"
        case .xcode: "schemeを署名なしでbuildし、テストがあればSimulatorで実行します。"
        }
    }

    public var idleDescription: String {
        switch system {
        case .swiftPackage: "ビルド後、成功した場合だけテストを続けます。"
        case .xcode: "schemeを確認し、Debug buildの成功後にテストを実行します。"
        }
    }
}

public struct ProjectValidationCheck: Codable, Equatable, Sendable {
    public let kind: ProjectValidationKind
    public let succeeded: Bool
    public let exitCode: Int32
    public let output: String
    public let outputWasTruncated: Bool
    public let duration: TimeInterval

    public init(
        kind: ProjectValidationKind,
        succeeded: Bool,
        exitCode: Int32,
        output: String,
        outputWasTruncated: Bool,
        duration: TimeInterval
    ) {
        self.kind = kind
        self.succeeded = succeeded
        self.exitCode = exitCode
        self.output = output
        self.outputWasTruncated = outputWasTruncated
        self.duration = duration
    }
}

public struct ProjectValidationReport: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let checks: [ProjectValidationCheck]
    public let artifacts: [ProjectValidationArtifact]?

    public init(
        startedAt: Date,
        finishedAt: Date,
        checks: [ProjectValidationCheck],
        artifacts: [ProjectValidationArtifact]? = nil
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.checks = checks
        self.artifacts = artifacts
    }

    public var succeeded: Bool {
        !checks.isEmpty && checks.allSatisfy(\.succeeded)
    }

    public var system: ProjectValidationSystem {
        checks.contains { $0.kind == .xcodeBuild || $0.kind == .xcodeTest }
            ? .xcode
            : .swiftPackage
    }
}

public enum ProjectValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedProject
    case commandUnavailable
    case xcodeUnavailable
    case xcodeSetupRequired
    case xcodeSchemeUnavailable(String)
    case timedOut(ProjectValidationKind)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProject:
            "Package.swiftまたはXcodeプロジェクトがあるソースを検証できます。"
        case .commandUnavailable:
            "Swiftツールチェーンを実行できません。Command Line Toolsを確認してください。"
        case .xcodeUnavailable:
            "xcodebuildを実行できません。Xcodeをインストールし、使用するXcodeを設定してください。"
        case .xcodeSetupRequired:
            "Xcodeの初回セットアップが完了していません。Xcodeを一度開き、ライセンスと必要コンポーネントを確認してください。"
        case let .xcodeSchemeUnavailable(container):
            "\(container)に利用可能なschemeがありません。XcodeのManage Schemesを確認してください。"
        case let .timedOut(kind):
            "\(kind.displayName)が3分で完了しなかったため停止しました。"
        }
    }
}

public protocol ProjectValidating: Sendable {
    func support(rootPath: String) async -> ProjectValidationSupport?
    func validate(rootPath: String) async throws -> ProjectValidationReport
}
