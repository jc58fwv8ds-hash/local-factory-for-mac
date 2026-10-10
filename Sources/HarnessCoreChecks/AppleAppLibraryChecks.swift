import Foundation
import HarnessCore

enum AppleAppLibraryChecks {
    static func run() throws {
        try platformSettingsParsing()
        try companionInstallationOrder()
        try independentWatchSelection()
    }

    private static func platformSettingsParsing() throws {
        let phone = AppleAppBuildSettingsParser.configuration(
            from: settingsOutput(
                product: "Memory",
                bundle: "local.harness.memory",
                productType: "com.apple.product-type.application",
                platform: "iphoneos",
                supported: "iphoneos iphonesimulator",
                extra: ""
            ),
            requestedPlatform: .iPhone,
            scheme: "Memory"
        )
        let watch = AppleAppBuildSettingsParser.configuration(
            from: settingsOutput(
                product: "Memory Watch App",
                bundle: "local.harness.memory.watchkitapp",
                productType: "com.apple.product-type.application.watchapp2",
                platform: "watchos",
                supported: "watchos watchsimulator",
                extra: "\"INFOPLIST_KEY_WKCompanionAppBundleIdentifier\": \"local.harness.memory\","
            ),
            requestedPlatform: .appleWatch,
            scheme: "Memory Watch App"
        )
        try expect(
            phone?.platform == .iPhone
                && phone?.scheme == "Memory"
                && phone?.hasUsableBundleIdentifier == true
                && watch?.platform == .appleWatch
                && watch?.watchRelationship == .requiresCompanion,
            "App catalog settings must distinguish iPhone and companion Watch products"
        )
        print("✓ App catalog parses iPhone and Apple Watch build products")
    }

    private static func companionInstallationOrder() throws {
        let app = makeApp(
            configurations: [
                configuration(platform: .iPhone, relationship: nil),
                configuration(platform: .appleWatch, relationship: .requiresCompanion)
            ]
        )
        let order = AppleAppInstallSelectionPolicy.installationOrder(
            requested: [.appleWatch],
            app: app
        )
        try expect(
            order == [.iPhone, .appleWatch],
            "Dependent Watch apps must install their iPhone companion first"
        )
        print("✓ Companion Watch selection automatically orders iPhone first")
    }

    private static func independentWatchSelection() throws {
        let app = makeApp(
            configurations: [
                configuration(platform: .appleWatch, relationship: .independent)
            ]
        )
        let order = AppleAppInstallSelectionPolicy.installationOrder(
            requested: [.appleWatch, .iPhone],
            app: app
        )
        try expect(
            order == [.appleWatch],
            "Independent Watch apps must remain installable without an iPhone product"
        )
        print("✓ Independent Watch apps remain independently selectable")
    }

    private static func configuration(
        platform: AppleAppPlatform,
        relationship: WatchAppRelationship?
    ) -> AppleAppBuildConfiguration {
        AppleAppBuildConfiguration(
            platform: platform,
            scheme: platform == .iPhone ? "Memory" : "Memory Watch App",
            productName: platform == .iPhone ? "Memory" : "Memory Watch App",
            bundleIdentifier: platform == .iPhone
                ? "local.harness.memory"
                : "local.harness.memory.watchkitapp",
            signingStyle: .automatic,
            hasDevelopmentTeam: true,
            watchRelationship: relationship
        )
    }

    private static func makeApp(
        configurations: [AppleAppBuildConfiguration]
    ) -> InstallableAppleApp {
        InstallableAppleApp(
            id: "memory",
            source: AppleAppSource(
                projectID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                projectName: "Memory",
                rootPath: "/tmp/Memory"
            ),
            container: XcodeProjectContainer(kind: .project, relativePath: "Memory.xcodeproj"),
            scheme: "Memory",
            displayName: "Memory",
            configurations: configurations
        )
    }

    private static func settingsOutput(
        product: String,
        bundle: String,
        productType: String,
        platform: String,
        supported: String,
        extra: String
    ) -> String {
        """
        warning: not json
        [{
          "target": "\(product)",
          "buildSettings": {
            "PRODUCT_NAME": "\(product)",
            "PRODUCT_BUNDLE_IDENTIFIER": "\(bundle)",
            "CODE_SIGN_STYLE": "Automatic",
            "DEVELOPMENT_TEAM": "PERSONALTEAM",
            "PRODUCT_TYPE": "\(productType)",
            "SUPPORTED_PLATFORMS": "\(supported)",
            "PLATFORM_NAME": "\(platform)",
            "WRAPPER_EXTENSION": "app",
            \(extra)
            "FULL_PRODUCT_NAME": "\(product).app"
          }
        }]
        """
    }
}
