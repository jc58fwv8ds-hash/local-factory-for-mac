import Foundation

public enum XcodeTestDestinationSelector {
    public static func preferred(from devices: [SimulatorDevice]) -> SimulatorDevice? {
        let iPhones = devices.filter {
            $0.runtimeIdentifier.contains(".iOS-")
                && $0.name.localizedCaseInsensitiveContains("iPhone")
                && UUID(uuidString: $0.id) != nil
        }
        return iPhones.first(where: { $0.state == .booted }) ?? iPhones.first
    }
}
