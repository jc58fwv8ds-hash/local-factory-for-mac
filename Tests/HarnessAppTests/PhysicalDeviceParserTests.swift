import Foundation
import HarnessCore
import Testing

struct PhysicalDeviceParserTests {
    private func device(reality: String?, udid: String) -> String {
        let reality = reality.map { "\"reality\": \"\($0)\"," } ?? ""
        return """
        {"identifier": "\(UUID().uuidString)",
         "hardwareProperties": {\(reality) "platform": "iOS", "deviceType": "iPhone", "udid": "\(udid)"},
         "deviceProperties": {"name": "テストの iPhone", "osVersionNumber": "27.0.1"},
         "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected"}}
        """
    }

    /// 2026-10-18: a paired iPhone whose tunnel is not up reports no `reality`; it is still a real device.
    @Test func realDeviceBeforeItsTunnelIsUpCountsAndSimulatorsDoNot() {
        let json = """
        {"result": {"devices": [\(device(reality: nil, udid: "00008150-000A1B2C3D4E5F60")),
                                \(device(reality: "simulated", udid: "5A1B2C3D-0000-4000-8000-000000000001"))]}}
        """
        let devices = PhysicalDeviceParser.devices(from: Data(json.utf8))
        #expect(devices.count == 1)
        #expect(devices.first?.platform == .iPhone)
        #expect(devices.first?.modelName == "iPhone")
    }
}

/// 2026-10-18: Xcode 27 words a missing Apple Account as `No Account for Team "…"`.
@Test func xcode27MissingAccountIsRecognised() {
    let output = #"error: No Account for Team "ABCDE12345". Add a new account in Accounts settings or verify that your accounts have valid credentials."#
    #expect(PhysicalDeviceBuildFailureClassifier.classify(output) == .accountMissing)
}
