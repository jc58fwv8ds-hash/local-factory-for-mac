import Foundation
import HarnessCore

enum PhysicalDeviceChecks {
    static func run() throws {
        try deviceParsing()
        try signingParsing()
        try readinessEvaluation()
        try failureClassification()
    }

    private static func deviceParsing() throws {
        let data = Data(
            """
            {
              "result": {
                "devices": [
                  {
                    "identifier": "11111111-1111-1111-1111-111111111111",
                    "connectionProperties": {
                      "pairingState": "paired",
                      "transportType": "wired"
                    },
                    "deviceProperties": {
                      "bootState": "booted",
                      "developerModeStatus": "enabled",
                      "name": "Test iPhone",
                      "osVersionNumber": "26.6"
                    },
                    "hardwareProperties": {
                      "deviceType": "iPhone",
                      "marketingName": "iPhone 14 Pro",
                      "platform": "iOS",
                      "reality": "physical",
                      "udid": "00001111-2222333344445555",
                      "serialNumber": "MUST-NOT-BE-RETAINED",
                      "ecid": 123456789
                    }
                  },
                  {
                    "identifier": "22222222-2222-2222-2222-222222222222",
                    "deviceProperties": {"name": "Simulator"},
                    "hardwareProperties": {
                      "deviceType": "iPhone",
                      "platform": "iOS",
                      "reality": "simulator",
                      "udid": "22222222-2222-2222-2222-222222222222"
                    }
                  },
                  {
                    "identifier": "33333333-3333-3333-3333-333333333333",
                    "deviceProperties": {"name": "iPad"},
                    "hardwareProperties": {
                      "deviceType": "iPad",
                      "platform": "iOS",
                      "reality": "physical",
                      "udid": "33333333-3333-3333-3333-333333333333"
                    }
                  },
                  {
                    "identifier": "44444444-4444-4444-4444-444444444444",
                    "connectionProperties": {
                      "pairingState": "paired",
                      "transportType": "wireless"
                    },
                    "deviceProperties": {
                      "bootState": "booted",
                      "developerModeStatus": "enabled",
                      "name": "Test Watch",
                      "osVersionNumber": "26.6"
                    },
                    "hardwareProperties": {
                      "deviceType": "AppleWatch",
                      "marketingName": "Apple Watch Series 10",
                      "platform": "watchOS",
                      "reality": "physical",
                      "udid": "44444444-4444-4444-4444-444444444444"
                    }
                  }
                ]
              }
            }
            """.utf8
        )
        let devices = PhysicalDeviceParser.devices(from: data)
        try expect(
            devices.count == 2
                && devices.contains {
                    $0.platform == .iPhone
                        && $0.name == "Test iPhone"
                        && $0.modelName == "iPhone 14 Pro"
                        && $0.connection == .wired
                        && $0.isPaired
                        && $0.isDeveloperModeEnabled
                }
                && devices.contains {
                    $0.platform == .appleWatch
                        && $0.name == "Test Watch"
                        && $0.modelName == "Apple Watch Series 10"
                },
            "Physical device parsing must retain bounded iPhone and Watch display state"
        )
        try expect(
            PhysicalDeviceParser.devices(from: Data("{}".utf8)).isEmpty,
            "Missing device data must produce a safe empty state"
        )
        print("✓ Physical Apple device parsing discards unsupported and sensitive fields")
    }

    private static func signingParsing() throws {
        let output = """
        warning [not json]
        [
          {
            "target": "RemoteApp",
            "buildSettings": {
              "PRODUCT_NAME": "RemoteApp",
              "PRODUCT_BUNDLE_IDENTIFIER": "local.harness.remote",
              "CODE_SIGN_STYLE": "Automatic",
              "DEVELOPMENT_TEAM": "PERSONALTEAM",
              "PRODUCT_TYPE": "com.apple.product-type.application",
              "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
              "PLATFORM_NAME": "iphoneos",
              "TARGET_BUILD_DIR": "/tmp/DerivedData/Build/Products/Debug-iphoneos",
              "FULL_PRODUCT_NAME": "RemoteApp.app"
            }
          }
        ]
        """
        let configuration = XcodeSigningSettingsParser.configuration(
            from: output,
            containerName: "RemoteApp.xcodeproj",
            scheme: "RemoteApp"
        )
        try expect(
            configuration?.signingStyle == .automatic
                && configuration?.hasDevelopmentTeam == true
                && configuration?.hasUsableBundleIdentifier == true
                && configuration?.isIOSApplication == true,
            "Signing settings must be extracted from noisy xcodebuild JSON"
        )
        print("✓ Xcode signing parser extracts only readiness-level settings")
    }

    private static func readinessEvaluation() throws {
        let device = PhysicalAppleDevice(
            id: "11111111-1111-1111-1111-111111111111",
            name: "Test iPhone",
            modelName: "iPhone",
            osVersion: "26.6",
            connection: .wired,
            isPaired: true,
            isDeveloperModeEnabled: true,
            isBooted: true
        )
        let missingTeam = PhysicalDeviceProjectConfiguration(
            containerName: "App.xcodeproj",
            scheme: "App",
            productName: "App",
            bundleIdentifier: "local.harness.app",
            signingStyle: .automatic,
            hasDevelopmentTeam: false,
            isIOSApplication: true
        )
        let blocked = PhysicalDeviceReadinessEvaluator.evaluate(
            device: device,
            project: missingTeam,
            preparation: DevicePreparationSnapshot(deviceIdentifier: device.id, pairing: .met, tunnel: .met,
                developerMode: .met, ddiServices: .met, passcode: .met)
        )
        try expect(
            blocked.requirements == [.selectDevelopmentTeam] && !blocked.canRun,
            "A Personal Team must be selected before an approved device run"
        )

        let readyProject = PhysicalDeviceProjectConfiguration(
            containerName: "App.xcodeproj",
            scheme: "App",
            productName: "App",
            bundleIdentifier: "local.harness.app",
            signingStyle: .automatic,
            hasDevelopmentTeam: true,
            isIOSApplication: true
        )
        try expect(
            PhysicalDeviceReadinessEvaluator.evaluate(
                device: device,
                project: readyProject,
                preparation: DevicePreparationSnapshot(deviceIdentifier: device.id, pairing: .met, tunnel: .met,
                    developerMode: .met, ddiServices: .met, passcode: .met)
            ).canRun,
            "A paired, unlocked Developer Mode iPhone with automatic signing must be runnable"
        )
        print("✓ Physical device readiness blocks signing until explicit setup is complete")
    }

    private static func failureClassification() throws {
        try expect(
            PhysicalDeviceBuildFailureClassifier.classify(
                "Signing for App requires a development team"
            ) == .teamMissing,
            "Team failures must receive focused guidance"
        )
        try expect(
            PhysicalDeviceBuildFailureClassifier.classify(
                "No signing certificate Apple Development found"
            ) == .certificateMissing,
            "Certificate failures must receive focused guidance"
        )
        print("✓ Signing failures are summarized without exposing raw build logs")
    }
}
