import Foundation

public enum XcodeTestDestinationSelector {
    /// The device Factory tested on last (2026-11-25): without it, "the first iPhone in the list" changed with the
    /// list's order and each newly booted device added 2-7 GB of its own data (22 GB of devices on 2026-11-25).
    public static let lastDeviceKey = "harness.testSimulatorID"

    /// A booted iPhone, else the one used last, else an iPhone of the newest iOS runtime.
    public static func preferred(from devices: [SimulatorDevice], last: String? = nil) -> SimulatorDevice? {
        let iPhones = devices.filter {
            $0.runtimeIdentifier.contains(".iOS-")
                && $0.name.localizedCaseInsensitiveContains("iPhone")
                && UUID(uuidString: $0.id) != nil
        }
        if let booted = iPhones.first(where: { $0.state == .booted }) { return booted }
        if let last, let used = iPhones.first(where: { $0.id == last }) { return used }
        let newest = iPhones.map { runtimeVersion($0.runtimeIdentifier) }.max { $0.lexicographicallyPrecedes($1) }
        return iPhones.first { runtimeVersion($0.runtimeIdentifier) == newest } ?? iPhones.first
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → [27, 0].
    static func runtimeVersion(_ identifier: String) -> [Int] {
        guard let range = identifier.range(of: ".iOS-") else { return [] }
        return identifier[range.upperBound...].split(separator: "-").compactMap { Int($0) }
    }
}
