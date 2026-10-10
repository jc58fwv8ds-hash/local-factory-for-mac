import Foundation

public enum DevicePreparationCheck: String, Codable, CaseIterable, Sendable {
    case pairing, tunnel, developerMode, ddiServices, passcode

    public var title: String {
        switch self {
        case .pairing: "Macとのペアリング"
        case .tunnel: "開発用の接続"
        case .developerMode: "Developer Mode"
        case .ddiServices: "開発用サービス"
        case .passcode: "端末の認証要求"
        }
    }

    public var guidance: String {
        switch self {
        case .pairing: "Xcodeで対象端末とのペアリングと信頼を確認してください。"
        case .tunnel: "対象端末との開発用通信が接続されていません。接続条件が変わってから再確認してください。"
        case .developerMode: "端末本体のDeveloper Modeを有効にしてください。WidgetKitの設定とは別です。"
        case .ddiServices: "Xcodeによる開発用サービスの準備がまだ完了していません。"
        case .passcode: "対象端末でロック解除・認証を行ってから再確認してください。"
        }
    }
}

public enum DevicePreparationState: String, Codable, Sendable {
    case met, notMet, unknown

    public var displayName: String {
        switch self {
        case .met: "確認済み"
        case .notMet: "準備が必要"
        case .unknown: "未確認（無効とは限りません）"
        }
    }
}

public enum DevicePreparationFailure: String, Codable, Error, Sendable {
    case toolUnavailable, timedOut, commandFailed, invalidResponse
}

/// An observation, not permission to run or proof of signing/application success.
public struct DevicePreparationSnapshot: Codable, Equatable, Sendable {
    public let deviceIdentifier: String
    public let observedAt: Date
    public let pairing: DevicePreparationState
    public let tunnel: DevicePreparationState
    public let developerMode: DevicePreparationState
    public let ddiServices: DevicePreparationState
    public let passcode: DevicePreparationState
    public let detailsFailure: DevicePreparationFailure?
    public let lockFailure: DevicePreparationFailure?

    public init(deviceIdentifier: String, observedAt: Date = .now,
                pairing: DevicePreparationState = .unknown, tunnel: DevicePreparationState = .unknown,
                developerMode: DevicePreparationState = .unknown, ddiServices: DevicePreparationState = .unknown,
                passcode: DevicePreparationState = .unknown,
                detailsFailure: DevicePreparationFailure? = nil, lockFailure: DevicePreparationFailure? = nil) {
        self.deviceIdentifier = deviceIdentifier
        self.observedAt = observedAt
        self.pairing = pairing
        self.tunnel = tunnel
        self.developerMode = developerMode
        self.ddiServices = ddiServices
        self.passcode = passcode
        self.detailsFailure = detailsFailure
        self.lockFailure = lockFailure
    }

    public func state(for check: DevicePreparationCheck) -> DevicePreparationState {
        switch check {
        case .pairing: pairing
        case .tunnel: tunnel
        case .developerMode: developerMode
        case .ddiServices: ddiServices
        case .passcode: passcode
        }
    }

    public func isCurrent(for identifier: String, at now: Date = .now) -> Bool {
        identifier.caseInsensitiveCompare(deviceIdentifier) == .orderedSame
            && (0...60).contains(now.timeIntervalSince(observedAt))
    }

    public func isReady(for identifier: String, at now: Date = .now) -> Bool {
        isCurrent(for: identifier, at: now) && detailsFailure == nil && lockFailure == nil
            && DevicePreparationCheck.allCases.allSatisfy { state(for: $0) == .met }
    }

    public func summary(at now: Date = .now) -> String {
        guard isCurrent(for: deviceIdentifier, at: now) else { return "確認結果が古いため、接続状態を再確認してください。" }
        if let unmet = DevicePreparationCheck.allCases.first(where: { state(for: $0) == .notMet }) {
            return unmet.guidance
        }
        if detailsFailure != nil || lockFailure != nil {
            return "端末の状態を十分に取得できませんでした。設定が無効とは断定できません。"
        }
        if DevicePreparationCheck.allCases.contains(where: { state(for: $0) == .unknown }) {
            return "取得した情報が一部のため、開発準備が整ったかはまだ確認できません。"
        }
        return "接続・開発用サービスを確認し、端末から認証要求は報告されませんでした。署名やアプリの起動成功は別途確認します。"
    }
}

public protocol DevicePreparationProviding: Sendable {
    func inspect(deviceIdentifier: String) async throws -> DevicePreparationSnapshot
}

public enum DevicePreparationError: LocalizedError, Sendable {
    case invalidIdentifier
    case notReady(DevicePreparationSnapshot)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "対象端末を安全に特定できません。一覧を更新してください。"
        case .notReady(let snapshot): snapshot.summary()
        }
    }
}
