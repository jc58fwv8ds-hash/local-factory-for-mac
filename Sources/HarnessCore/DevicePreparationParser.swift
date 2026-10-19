import Foundation

/// Consumes only the supported JSON interface. Unknown versions/values never imply readiness.
enum DevicePreparationParser {
    static let supportedVersions: ClosedRange<Int> = 3...5
    static func details(_ data: Data, identifier: String, observedAt: Date) throws -> DevicePreparationSnapshot {
        let value: Response<Details> = try decode(data, command: "details")
        guard value.result.identifier.caseInsensitiveCompare(identifier) == .orderedSame else {
            throw DevicePreparationFailure.invalidResponse
        }
        let connection = value.result.connectionProperties
        let properties = value.result.deviceProperties
        return DevicePreparationSnapshot(
            deviceIdentifier: identifier, observedAt: observedAt,
            pairing: state(connection?.pairingState, yes: "paired", no: "unpaired"),
            tunnel: state(connection?.tunnelState, yes: "connected", no: "disconnected"),
            developerMode: state(properties?.developerModeStatus, yes: "enabled", no: "disabled"),
            ddiServices: boolean(properties?.ddiServicesAvailable))
    }

    static func lock(_ data: Data, identifier: String) throws -> DevicePreparationState {
        let value: Response<Lock> = try decode(data, command: "lockState")
        guard value.result.deviceIdentifier.caseInsensitiveCompare(identifier) == .orderedSame else {
            throw DevicePreparationFailure.invalidResponse
        }
        // unlockedSinceBoot is historical, not the present lock/authorization state.
        guard let required = value.result.passcodeRequired else { return .unknown }
        return required ? .notMet : .met
    }

    private static func decode<T: Decodable>(_ data: Data, command: String) throws -> Response<T> {
        guard data.count <= 2_000_000,
              let response = try? JSONDecoder().decode(Response<T>.self, from: data),
              // Xcode 27's devicectl writes version 5 with the same fields (checked on a real iPhone, 2026-10-18).
              Self.supportedVersions.contains(response.info.jsonVersion),
              response.info.commandType == "devicectl.device.info.\(command)",
              response.info.outcome == "success" else { throw DevicePreparationFailure.invalidResponse }
        return response
    }

    private static func state(_ value: String?, yes: String, no: String) -> DevicePreparationState {
        switch value?.lowercased() {
        case yes: .met
        case no: .notMet
        default: .unknown
        }
    }

    private static func boolean(_ value: Bool?) -> DevicePreparationState {
        switch value {
        case true: .met
        case false: .notMet
        case nil: .unknown
        }
    }

    private struct Response<T: Decodable>: Decodable { let info: Info; let result: T }
    private struct Info: Decodable { let jsonVersion: Int; let commandType: String; let outcome: String }
    private struct Details: Decodable {
        let identifier: String
        let connectionProperties: Connection?
        let deviceProperties: Properties?
    }
    private struct Connection: Decodable { let pairingState: String?; let tunnelState: String? }
    private struct Properties: Decodable { let developerModeStatus: String?; let ddiServicesAvailable: Bool? }
    private struct Lock: Decodable { let deviceIdentifier: String; let passcodeRequired: Bool? }
}
