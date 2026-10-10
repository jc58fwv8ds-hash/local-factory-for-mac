import Foundation
import HarnessCore

enum VoiceEngineInstallerError: LocalizedError, Equatable {
    case unsupportedHardware
    case insufficientStorage
    case packagedResourcesMissing
    case existingInstallation
    case incompatiblePartialInstallation
    case bootstrapDownloadFailed
    case bootstrapIntegrityFailed
    case runtimeInstallationFailed
    case modelInstallationFailed
    case activationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            "この音声エンジンはApple Silicon搭載Mac専用です。"
        case .insufficientStorage:
            "安全な導入には6GB以上の空き容量が必要です。"
        case .packagedResourcesMissing:
            "配布アプリ内の音声エンジン設定を確認できませんでした。"
        case .existingInstallation:
            "既存の音声エンジンがあります。状態を再確認してください。"
        case .incompatiblePartialInstallation:
            "以前の導入データは現在の版と互換性がありません。破棄してやり直してください。"
        case .bootstrapDownloadFailed:
            "安全なセットアップツールを取得できませんでした。"
        case .bootstrapIntegrityFailed:
            "セットアップツールの内容が公式の照合値と一致しません。"
        case .runtimeInstallationFailed:
            "専用の音声実行環境を準備できませんでした。"
        case .modelInstallationFailed:
            "音声モデルの取得または内容検査に失敗しました。"
        case .activationFailed:
            "検査済みの音声エンジンを有効化できませんでした。"
        }
    }
}

protocol VoiceEngineInstalling: Sendable {
    func preflight() async -> VoiceEngineInstallationPreflight
    func hasResumableInstallation() async -> Bool
    func install(
        onProgress: @escaping @Sendable (VoiceEngineInstallationProgress) async -> Void
    ) async throws
    func discardPartialInstallation() async throws
    func removeInstallation() async throws
}

protocol VoiceEngineInstallationCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onOutput: (@Sendable (String) async -> Void)?
    ) async throws -> Int32
}

actor BoundedVoiceEngineInstallationRunner: VoiceEngineInstallationCommandRunning {
    private let runner = BoundedCommandRunner(
        timeout: .seconds(14_400),
        maximumOutputBytes: 20_000
    )

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onOutput: (@Sendable (String) async -> Void)?
    ) async throws -> Int32 {
        try await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            onOutput: onOutput
        ).exitCode
    }
}
