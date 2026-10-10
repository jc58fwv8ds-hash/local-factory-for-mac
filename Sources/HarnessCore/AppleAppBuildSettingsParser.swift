import Foundation

public enum AppleAppBuildSettingsParser {
    public static func configuration(
        from output: String,
        requestedPlatform: AppleAppPlatform,
        scheme: String = "App"
    ) -> AppleAppBuildConfiguration? {
        guard let entries = decodeEntries(from: output) else { return nil }
        return entries.lazy
            .filter { isApplication($0.buildSettings) }
            .filter { platform(from: $0.buildSettings) == requestedPlatform }
            .compactMap { makeConfiguration(entry: $0, platform: requestedPlatform, scheme: scheme) }
            .first
    }

    private static func makeConfiguration(
        entry: AppleBuildSettingsEntry,
        platform: AppleAppPlatform,
        scheme: String
    ) -> AppleAppBuildConfiguration? {
        let settings = entry.buildSettings
        let style: XcodeSigningStyle
        switch settings["CODE_SIGN_STYLE"]?.lowercased() {
        case "automatic": style = .automatic
        case "manual": style = .manual
        default: style = .unknown
        }

        let fallback = platform == .iPhone ? "iPhone App" : "Watch App"
        guard let productName = bounded(settings["PRODUCT_NAME"])
            ?? bounded(entry.target)
            ?? bounded(fallback) else { return nil }

        return AppleAppBuildConfiguration(
            platform: platform,
            scheme: bounded(scheme) ?? "App",
            productName: productName,
            bundleIdentifier: bounded(settings["PRODUCT_BUNDLE_IDENTIFIER"]),
            signingStyle: style,
            hasDevelopmentTeam: bounded(settings["DEVELOPMENT_TEAM"]) != nil,
            watchRelationship: relationship(settings: settings, platform: platform),
            companionBundleIdentifier: companionIdentifier(settings),
            targetBuildDirectory: boundedPath(settings["TARGET_BUILD_DIR"]),
            fullProductName: bounded(settings["FULL_PRODUCT_NAME"]),
            appIconName: bounded(settings["ASSETCATALOG_COMPILER_APPICON_NAME"])
        )
    }

    private static func companionIdentifier(_ settings: [String: String]) -> String? {
        bounded(settings["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"])
            ?? bounded(settings["WK_COMPANION_APP_BUNDLE_IDENTIFIER"])
    }

    private static func relationship(
        settings: [String: String],
        platform: AppleAppPlatform
    ) -> WatchAppRelationship? {
        guard platform == .appleWatch else { return nil }
        if isTrue(settings["INFOPLIST_KEY_WKWatchOnly"]) {
            return .watchOnly
        }
        if isTrue(settings["INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp"]) {
            return .independent
        }
        let companionKeys = [
            "INFOPLIST_KEY_WKCompanionAppBundleIdentifier",
            "WK_COMPANION_APP_BUNDLE_IDENTIFIER"
        ]
        if companionKeys.contains(where: { bounded(settings[$0]) != nil }) {
            return .requiresCompanion
        }
        return .requiresCompanion
    }

    private static func platform(from settings: [String: String]) -> AppleAppPlatform? {
        let productType = settings["PRODUCT_TYPE"]?.lowercased() ?? ""
        let current = settings["PLATFORM_NAME"]?.lowercased() ?? ""
        let supported = settings["SUPPORTED_PLATFORMS"]?.lowercased() ?? ""
        if productType.contains("watchapp")
            || current == "watchos"
            || supported.split(separator: " ").contains("watchos") {
            return .appleWatch
        }
        if current == "iphoneos"
            || supported.split(separator: " ").contains("iphoneos") {
            return .iPhone
        }
        return nil
    }

    private static func isApplication(_ settings: [String: String]) -> Bool {
        let productType = settings["PRODUCT_TYPE"]?.lowercased() ?? ""
        return productType == "com.apple.product-type.application"
            || productType.contains("watchapp")
            || settings["WRAPPER_EXTENSION"]?.lowercased() == "app"
    }

    private static func decodeEntries(from output: String) -> [AppleBuildSettingsEntry]? {
        guard let end = output.lastIndex(of: "]") else { return nil }
        for start in output.indices.filter({ output[$0] == "[" }).suffix(256) where start < end {
            let data = Data(output[start...end].utf8)
            if let entries = try? JSONDecoder().decode([AppleBuildSettingsEntry].self, from: data) {
                return entries
            }
        }
        return nil
    }

    private static func isTrue(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["yes", "true", "1"].contains(value.lowercased())
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 1_000 else { return nil }
        return cleaned
    }

    private static func boundedPath(_ value: String?) -> String? {
        guard let value = bounded(value), value.count <= 4_096 else { return nil }
        return value
    }
}

private struct AppleBuildSettingsEntry: Decodable {
    let target: String?
    let buildSettings: [String: String]
}
