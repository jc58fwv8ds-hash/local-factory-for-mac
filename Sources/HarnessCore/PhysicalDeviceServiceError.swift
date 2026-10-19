import Foundation

public enum PhysicalDeviceBuildFailure: String, Equatable, Sendable {
    case accountMissing
    case teamMissing
    case certificateMissing
    case provisioningFailed
    case destinationUnavailable
    case deviceLocked
    case generic

    public var guidance: String {
        switch self {
        case .accountMissing:
            "XcodeのSettings > Accountsで無料のApple Accountを追加してください。"
        case .teamMissing:
            "XcodeのSigning & CapabilitiesでTeamにPersonal Teamを選択してください。"
        case .certificateMissing:
            "XcodeのAccountsでPersonal Teamを選び、Manage CertificatesからApple Development証明書を作成してください。"
        case .provisioningFailed:
            "Automatic SigningとBundle Identifierを確認してから、もう一度実行してください。"
        case .destinationUnavailable:
            "iPhoneをUSBで接続し、ロックを解除して「信頼」を確認してください。"
        case .deviceLocked:
            "iPhoneのロックを解除したまま、もう一度実行してください。"
        case .generic:
            "Xcodeでプロジェクトを開き、Signing & Capabilitiesの警告を確認してください。"
        }
    }
}

public enum PhysicalDeviceBuildFailureClassifier {
    public static func classify(_ output: String) -> PhysicalDeviceBuildFailure {
        let value = output.lowercased()
        // Xcode 27: `No Account for Team "…". Add a new account in Accounts settings` (2026-10-18, a real iPhone).
        if value.contains("no accounts") || value.contains("add an account") || value.contains("no account for team")
            || value.contains("add a new account") {
            return .accountMissing
        }
        if value.contains("requires a development team")
            || value.contains("development team is required") {
            return .teamMissing
        }
        if value.contains("no signing certificate")
            || value.contains("signing certificate \"") {
            return .certificateMissing
        }
        if value.contains("device is locked") || value.contains("locked device") {
            return .deviceLocked
        }
        if value.contains("destination")
            && (value.contains("not found") || value.contains("unavailable")) {
            return .destinationUnavailable
        }
        if value.contains("provisioning profile")
            || value.contains("failed to register bundle identifier") {
            return .provisioningFailed
        }
        return .generic
    }
}

public enum PhysicalDeviceServiceError: LocalizedError, Equatable, Sendable {
    case xcodeUnavailable
    case deviceServiceUnavailable
    case projectUnavailable
    case schemeUnavailable
    case settingsUnavailable
    case invalidDevice
    case notReady(PhysicalDeviceSetupRequirement)
    case buildFailed(PhysicalDeviceBuildFailure)
    case appProductUnavailable
    case installFailed
    case launchFailed
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .xcodeUnavailable:
            "Xcodeの開発ツールを実行できません。Xcodeの初期設定を確認してください。"
        case .deviceServiceUnavailable:
            "iPhoneの接続情報を取得できません。USB接続とロック解除を確認してください。"
        case .projectUnavailable:
            "接続フォルダ内にXcodeプロジェクトが見つかりません。"
        case .schemeUnavailable:
            "共有されたXcode schemeが見つかりません。XcodeでschemeをSharedにしてください。"
        case .settingsUnavailable:
            "iOSアプリのビルド設定を安全に読み取れませんでした。"
        case .invalidDevice:
            "選択したiPhoneの実行用ハンドルが不正です。一覧を更新してください。"
        case let .notReady(requirement):
            "「\(requirement.title)」の設定が必要です。Xcode設定を開いて確認してください。"
        case let .buildFailed(reason):
            "実機向けビルドを完了できませんでした。\(reason.guidance)"
        case .appProductUnavailable:
            "ビルド済みアプリを安全な一時領域内で確認できませんでした。"
        case .installFailed:
            "iPhoneへアプリをインストールできませんでした。接続、空き容量、署名を確認してください。"
        case .launchFailed:
            "インストールは完了しましたが、iPhoneでアプリを起動できませんでした。ロックを解除してください。"
        case .timedOut:
            "実機操作が3分で完了しなかったため停止しました。"
        }
    }
}
