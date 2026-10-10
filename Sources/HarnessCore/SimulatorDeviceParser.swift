import Foundation

public enum SimulatorDeviceParser {
    public static func devices(from output: String) -> [SimulatorDevice] {
        guard let json = jsonData(from: output),
              let root = try? JSONDecoder().decode(DeviceList.self, from: json) else {
            return []
        }

        return root.devices.flatMap { runtimeIdentifier, payloads in
            payloads.compactMap { payload in
                guard payload.isAvailable != false,
                      UUID(uuidString: payload.udid) != nil else { return nil }
                return SimulatorDevice(
                    id: payload.udid,
                    name: payload.name,
                    runtimeIdentifier: runtimeIdentifier,
                    runtimeName: runtimeName(from: runtimeIdentifier),
                    state: state(from: payload.state)
                )
            }
        }
        .sorted(by: deviceOrder)
        .prefix(100)
        .map { $0 }
    }

    public static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        return data.count >= signature.count
            && data.prefix(signature.count).elementsEqual(signature)
    }

    private static func jsonData(from output: String) -> Data? {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}") else { return nil }
        return String(output[start...end]).data(using: .utf8)
    }

    private static func state(from rawValue: String) -> SimulatorDeviceState {
        switch rawValue.lowercased() {
        case "booted": .booted
        case "shutdown": .shutdown
        default: .other
        }
    }

    private static func runtimeName(from identifier: String) -> String {
        let component = identifier.split(separator: ".").last.map(String.init) ?? identifier
        guard let separator = component.firstIndex(of: "-") else { return component }
        let platform = String(component[..<separator])
        let version = component[component.index(after: separator)...]
            .replacingOccurrences(of: "-", with: ".")
        return "\(platform) \(version)"
    }

    private static func deviceOrder(_ lhs: SimulatorDevice, _ rhs: SimulatorDevice) -> Bool {
        if lhs.state == .booted && rhs.state != .booted { return true }
        if rhs.state == .booted && lhs.state != .booted { return false }
        let runtimeOrder = lhs.runtimeName.localizedStandardCompare(rhs.runtimeName)
        if runtimeOrder != .orderedSame { return runtimeOrder == .orderedDescending }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    private struct DeviceList: Decodable {
        let devices: [String: [DevicePayload]]
    }

    private struct DevicePayload: Decodable {
        let name: String
        let udid: String
        let state: String
        let isAvailable: Bool?
    }
}
