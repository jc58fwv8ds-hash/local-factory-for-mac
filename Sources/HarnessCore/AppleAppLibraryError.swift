import Foundation

public enum AppleAppLibraryError: LocalizedError, Equatable, Sendable {
    case xcodeUnavailable
    case invalidSelection
    case incompatibleDevice
    case deviceNotPaired
    case developerModeRequired
    case deviceLocked
    case automaticSigningRequired
    case developmentTeamRequired
    case bundleIdentifierRequired
    case settingsUnavailable
    case buildFailed(PhysicalDeviceBuildFailure)
    case appProductUnavailable
    case installFailed(AppleAppPlatform)
    case launchFailed(AppleAppPlatform)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .xcodeUnavailable:
            "Xcodeの開発ツールを利用できません。Xcodeの初期設定を確認してください。"
        case .invalidSelection:
            "選択したアプリを安全に確認できませんでした。一覧を更新してください。"
        case .incompatibleDevice:
            "選択したアプリと端末の種類が一致しません。一覧を更新してください。"
        case .deviceNotPaired:
            "端末をMacとペアリングし、信頼を許可してください。"
        case .developerModeRequired:
            "端末のDeveloper Modeを有効にしてください。"
        case .deviceLocked:
            "端末のロックを解除したまま、もう一度実行してください。"
        case .automaticSigningRequired:
            "XcodeでAutomatically manage signingを有効にしてください。"
        case .developmentTeamRequired:
            "Xcodeで無料のPersonal Teamを選択してください。"
        case .bundleIdentifierRequired:
            "Xcodeで固有のBundle Identifierを設定してください。"
        case .settingsUnavailable:
            "選択したアプリの実機向け設定を読み取れませんでした。"
        case let .buildFailed(reason):
            "実機向けビルドを完了できませんでした。\(reason.guidance)"
        case .appProductUnavailable:
            "ビルド済みアプリを安全な一時領域内で確認できませんでした。"
        case let .installFailed(platform):
            "\(platform.displayName)へインストールできませんでした。接続、空き容量、署名を確認してください。"
        case let .launchFailed(platform):
            "インストールは完了しましたが、\(platform.displayName)で起動できませんでした。ロックを解除してください。"
        case .timedOut:
            "実機操作が3分で完了しなかったため停止しました。"
        }
    }
}
