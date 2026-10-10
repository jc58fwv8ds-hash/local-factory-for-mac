import Foundation

public enum ValidationFailureDomain: String, Equatable, Hashable, Sendable {
    case implementation
    case testBehavior
    case toolchain
    case simulator
    case signing
    case dependency
    case resources
    case mixed
    case unknown

    public var permitsCodeChanges: Bool {
        self == .implementation || self == .testBehavior
    }

    public var title: String {
        switch self {
        case .implementation: "コード内の原因候補を確認しました"
        case .testBehavior: "テスト結果の不一致を確認しました"
        case .toolchain: "Xcode・開発ツールの準備が必要です"
        case .simulator: "Simulatorの準備が必要です"
        case .signing: "署名設定の確認が必要です"
        case .dependency: "依存関係または通信の復旧が必要です"
        case .resources: "Macの空き容量またはメモリの確認が必要です"
        case .mixed: "コードと実行環境の問題が混ざっています"
        case .unknown: "原因の種類をまだ安全に特定できません"
        }
    }

    public var nextAction: String {
        switch self {
        case .implementation:
            "表示されたソースだけを小さく修正し、同じビルドとテストをやり直します。"
        case .testBehavior:
            "失敗したテストの期待値と実際の動作を照合し、小さく修正して再検証します。"
        case .toolchain:
            "Xcodeの初回設定、ライセンス、Command Line Toolsを確認してから再検証します。"
        case .simulator:
            "XcodeのComponentsと利用できるiPhone Simulatorを確認してから再検証します。"
        case .signing:
            "XcodeのSigning & CapabilitiesでAutomatic SigningとTeamを確認してから再検証します。"
        case .dependency:
            "通信状態と依存パッケージの取得状態を確認し、同じ検証をやり直します。"
        case .resources:
            "起動ディスクの空き容量と使用中のアプリを確認し、余裕を作ってから再検証します。"
        case .mixed:
            "先に実行環境を直して再検証し、残ったコードの問題だけを修正対象にします。"
        case .unknown:
            "エラー出力を確認して同じ検証をもう一度行い、原因が再現してから修正を決めます。"
        }
    }
}

public struct ValidationFailureAssessment: Equatable, Sendable {
    public let domain: ValidationFailureDomain

    public init(domain: ValidationFailureDomain) {
        self.domain = domain
    }

    public var permitsCodeChanges: Bool { domain.permitsCodeChanges }
    public var title: String { domain.title }
    public var nextAction: String { domain.nextAction }
}

public enum ValidationFailureClassifier {
    private static let maximumInspectedCharacters = 120_000

    public static func classify(
        report: ProjectValidationReport,
        analysis: BuildFailureAnalysis?
    ) -> ValidationFailureAssessment {
        guard !report.succeeded else {
            return ValidationFailureAssessment(domain: .unknown)
        }
        let output = boundedOutput(report).lowercased()
        let environmentDomains = detectedEnvironmentDomains(in: output)
        let hasImplementation = analysis?.diagnostics.isEmpty == false
        let hasFailedTestKind = report.checks.contains {
            !$0.succeeded && ($0.kind == .test || $0.kind == .xcodeTest)
        }
        let hasTestBehavior = hasFailedTestKind && containsAny(output, testMarkers)

        if environmentDomains.count > 1
            || (!environmentDomains.isEmpty && (hasImplementation || hasTestBehavior)) {
            return ValidationFailureAssessment(domain: .mixed)
        }
        if let environment = environmentDomains.first {
            return ValidationFailureAssessment(domain: environment)
        }
        if hasImplementation {
            return ValidationFailureAssessment(domain: .implementation)
        }
        if hasFailedTestKind {
            return ValidationFailureAssessment(domain: .testBehavior)
        }
        return ValidationFailureAssessment(domain: .unknown)
    }

    private static func detectedEnvironmentDomains(
        in output: String
    ) -> Set<ValidationFailureDomain> {
        var domains = Set<ValidationFailureDomain>()
        if containsAny(output, toolchainMarkers) { domains.insert(.toolchain) }
        if containsAny(output, simulatorMarkers) { domains.insert(.simulator) }
        if containsAny(output, signingMarkers) { domains.insert(.signing) }
        if containsAny(output, dependencyMarkers) { domains.insert(.dependency) }
        if containsAny(output, resourceMarkers) { domains.insert(.resources) }
        return domains
    }

    private static func boundedOutput(_ report: ProjectValidationReport) -> String {
        let combined = report.checks.filter { !$0.succeeded }.map(\.output)
            .joined(separator: "\n")
        guard combined.count > maximumInspectedCharacters else { return combined }
        let half = maximumInspectedCharacters / 2
        return String(combined.prefix(half)) + "\n" + String(combined.suffix(half))
    }

    private static func containsAny(_ value: String, _ markers: [String]) -> Bool {
        markers.contains { value.contains($0) }
    }

    private static let toolchainMarkers = [
        "invalid active developer path", "xcode license", "xcode-select",
        "unable to find utility \"xcodebuild\"", "sdk cannot be located",
        "xcodeの初回セットアップ", "command line tools",
        "テストの実行を確認できませんでした"
    ]
    private static let simulatorMarkers = [
        "unable to find a destination", "no available devices", "coresimulator",
        "simulator is not available", "利用できるiphone simulator",
        "simulatorを確認できません"
    ]
    private static let signingMarkers = [
        "requires a development team", "no signing certificate",
        "provisioning profile", "code signing is required",
        "failed to register bundle identifier"
    ]
    private static let dependencyMarkers = [
        "failed to clone repository", "could not resolve host",
        "network connection was lost", "internet connection appears to be offline",
        "package resolution failed", "failed fetching"
    ]
    private static let resourceMarkers = [
        "no space left on device", "disk full", "out of memory",
        "cannot allocate memory", "too many open files"
    ]
    private static let testMarkers = [
        "xctassert", "test run failed", "test case '", " tests failed",
        "test failed", "exited with unexpected signal"
    ]
}
