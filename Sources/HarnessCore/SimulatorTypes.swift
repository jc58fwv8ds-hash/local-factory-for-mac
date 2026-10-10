import Foundation

public enum SimulatorDeviceState: String, Equatable, Sendable {
    case booted
    case shutdown
    case other

    public var displayName: String {
        switch self {
        case .booted: "起動中"
        case .shutdown: "停止中"
        case .other: "処理中"
        }
    }
}

public struct SimulatorDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let runtimeIdentifier: String
    public let runtimeName: String
    public let state: SimulatorDeviceState

    public init(
        id: String,
        name: String,
        runtimeIdentifier: String,
        runtimeName: String,
        state: SimulatorDeviceState
    ) {
        self.id = id
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
        self.state = state
    }
}

public struct SimulatorScreenshot: Equatable, Sendable {
    public let device: SimulatorDevice
    public let pngData: Data
    public let capturedAt: Date

    public init(device: SimulatorDevice, pngData: Data, capturedAt: Date = .now) {
        self.device = device
        self.pngData = pngData
        self.capturedAt = capturedAt
    }
}

public enum SimulatorServiceError: LocalizedError, Equatable, Sendable {
    case xcodeUnavailable
    case serviceUnavailable(String)
    case invalidDevice
    case deviceNotBooted
    case screenshotInvalid
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .xcodeUnavailable:
            "simctlを実行できません。XcodeとSimulatorコンポーネントを確認してください。"
        case let .serviceUnavailable(detail):
            detail.isEmpty
                ? "Simulatorサービスへ接続できません。XcodeのDevice Hubを一度開いてください。"
                : "Simulatorサービスへ接続できません：\(detail)"
        case .invalidDevice:
            "選択したSimulatorの識別子が不正です。端末一覧を更新してください。"
        case .deviceNotBooted:
            "スクリーンショットの前にSimulatorを起動してください。"
        case .screenshotInvalid:
            "Simulatorから有効なPNG画像を取得できませんでした。"
        case .timedOut:
            "Simulator操作が3分で完了しなかったため停止しました。"
        }
    }
}

public protocol SimulatorProviding: Sendable {
    func listDevices() async throws -> [SimulatorDevice]
    func boot(_ device: SimulatorDevice) async throws
    func captureScreenshot(of device: SimulatorDevice) async throws -> SimulatorScreenshot
}
