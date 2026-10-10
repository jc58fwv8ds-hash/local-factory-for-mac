import Foundation

public enum PhysicalDeviceParser {
    public static func devices(from data: Data) -> [PhysicalAppleDevice] {
        guard data.count <= 2_000_000,
              let response = try? JSONDecoder().decode(DeviceResponse.self, from: data) else {
            return []
        }

        return (response.result?.devices ?? []).compactMap(makeDevice).sorted {
            if $0.connection != $1.connection { return $0.connection == .wired }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func makeDevice(_ value: DeviceValue) -> PhysicalAppleDevice? {
        let hardware = value.hardwareProperties
        let properties = value.deviceProperties
        guard hardware?.reality?.lowercased() == "physical",
              let platform = platform(from: hardware),
              let identifier = validatedIdentifier(value.identifier),
              let destinationIdentifier = validatedIdentifier(hardware?.udid),
              let name = bounded(properties?.name, fallback: platform.displayName),
              let modelName = bounded(hardware?.marketingName, fallback: platform.displayName),
              let osVersion = bounded(properties?.osVersionNumber, fallback: platformOSName(platform)) else {
            return nil
        }

        return PhysicalAppleDevice(
            id: UUID().uuidString,
            platform: platform,
            deviceIdentifier: identifier,
            destinationIdentifier: destinationIdentifier,
            name: name,
            modelName: modelName,
            osVersion: osVersion,
            connection: connection(from: value.connectionProperties?.transportType),
            isPaired: value.connectionProperties?.pairingState?.lowercased() == "paired",
            isDeveloperModeEnabled: properties?.developerModeStatus?.lowercased() == "enabled",
            isBooted: properties?.bootState?.lowercased() == "booted"
        )
    }

    private static func platform(from hardware: DeviceHardwareProperties?) -> AppleAppPlatform? {
        let platform = hardware?.platform?.lowercased() ?? ""
        let deviceType = hardware?.deviceType?.lowercased() ?? ""
        if platform == "ios" && deviceType == "iphone" {
            return .iPhone
        }
        if platform == "watchos" || deviceType.contains("watch") {
            return .appleWatch
        }
        return nil
    }

    private static func platformOSName(_ platform: AppleAppPlatform) -> String {
        platform == .iPhone ? "iOS" : "watchOS"
    }

    private static func validatedIdentifier(_ value: String?) -> String? {
        guard let value,
              (8...80).contains(value.count),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).contains($0)
              }) else { return nil }
        return value
    }

    private static func bounded(_ value: String?, fallback: String) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
        guard !cleaned.isEmpty, cleaned.count <= 100 else { return nil }
        return cleaned
    }

    private static func connection(from value: String?) -> PhysicalDeviceConnection {
        switch value?.lowercased() {
        case "wired": .wired
        case "wireless", "wifi": .wireless
        default: .unknown
        }
    }
}

private struct DeviceResponse: Decodable {
    let result: DeviceResult?
}

private struct DeviceResult: Decodable {
    let devices: [DeviceValue]?
}

private struct DeviceValue: Decodable {
    let identifier: String?
    let connectionProperties: DeviceConnectionProperties?
    let deviceProperties: DeviceProperties?
    let hardwareProperties: DeviceHardwareProperties?
}

private struct DeviceConnectionProperties: Decodable {
    let pairingState: String?
    let transportType: String?
}

private struct DeviceProperties: Decodable {
    let bootState: String?
    let developerModeStatus: String?
    let name: String?
    let osVersionNumber: String?
}

private struct DeviceHardwareProperties: Decodable {
    let deviceType: String?
    let marketingName: String?
    let platform: String?
    let reality: String?
    let udid: String?
}
