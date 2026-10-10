import Foundation
import HarnessCore

enum SimulatorChecks {
    static func run() throws {
        let output = """
        simctl diagnostic warning before JSON
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
              {
                "name" : "iPhone 17 Pro",
                "udid" : "11111111-1111-1111-1111-111111111111",
                "state" : "Shutdown",
                "isAvailable" : true
              },
              {
                "name" : "Unavailable iPhone",
                "udid" : "22222222-2222-2222-2222-222222222222",
                "state" : "Shutdown",
                "isAvailable" : false
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-0" : [
              {
                "name" : "Apple Watch Series 11",
                "udid" : "33333333-3333-3333-3333-333333333333",
                "state" : "Booted",
                "isAvailable" : true
              },
              {
                "name" : "Invalid Device",
                "udid" : "not-a-udid",
                "state" : "Booted",
                "isAvailable" : true
              }
            ]
          }
        }
        trailing diagnostic
        """

        let devices = SimulatorDeviceParser.devices(from: output)
        try expect(
            devices.count == 2
                && devices[0].name == "Apple Watch Series 11"
                && devices[0].state == .booted
                && devices[0].runtimeName == "watchOS 26.0"
                && devices[1].name == "iPhone 17 Pro"
                && devices[1].state == .shutdown
                && devices[1].runtimeName == "iOS 26.5",
            "Simulator devices must be bounded, validated, and ordered deterministically"
        )
        print("✓ Simulator device parsing rejects unsafe and unavailable entries")

        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
        let invalidImage = Data([137, 80, 78, 71, 0])
        try expect(
            SimulatorDeviceParser.isPNG(png)
                && !SimulatorDeviceParser.isPNG(invalidImage),
            "Simulator screenshots must have a valid PNG signature"
        )
        print("✓ Simulator screenshot validation rejects invalid image data")
    }
}
