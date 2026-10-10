import Foundation

public enum XcodeSigningSettingsParser {
    public static func configuration(
        from output: String,
        containerName: String,
        scheme: String
    ) -> PhysicalDeviceProjectConfiguration? {
        guard let values = decodeEntries(from: output),
              let entry = preferredEntry(in: values) else { return nil }
        let settings = entry.buildSettings
        let style: XcodeSigningStyle
        switch settings["CODE_SIGN_STYLE"]?.lowercased() {
        case "automatic": style = .automatic
        case "manual": style = .manual
        default: style = .unknown
        }

        return PhysicalDeviceProjectConfiguration(
            containerName: bounded(containerName) ?? "Xcodeプロジェクト",
            scheme: bounded(scheme) ?? "App",
            productName: bounded(settings["PRODUCT_NAME"])
                ?? bounded(entry.target)
                ?? "iOS App",
            bundleIdentifier: bounded(settings["PRODUCT_BUNDLE_IDENTIFIER"]),
            signingStyle: style,
            hasDevelopmentTeam: bounded(settings["DEVELOPMENT_TEAM"]) != nil,
            isIOSApplication: isIOSApplication(settings),
            targetBuildDirectory: boundedPath(settings["TARGET_BUILD_DIR"]),
            fullProductName: bounded(settings["FULL_PRODUCT_NAME"])
        )
    }

    private static func decodeEntries(from output: String) -> [BuildSettingsEntry]? {
        let starts = output.indices.filter { output[$0] == "[" }.suffix(256)
        guard let end = output.lastIndex(of: "]") else { return nil }
        for start in starts where start < end {
            let data = Data(output[start...end].utf8)
            if let entries = try? JSONDecoder().decode([BuildSettingsEntry].self, from: data) {
                return entries
            }
        }
        return nil
    }

    private static func preferredEntry(in entries: [BuildSettingsEntry]) -> BuildSettingsEntry? {
        entries.first { isIOSApplication($0.buildSettings) }
            ?? entries.first { $0.buildSettings["WRAPPER_EXTENSION"]?.lowercased() == "app" }
    }

    private static func isIOSApplication(_ settings: [String: String]) -> Bool {
        let isApplication = settings["PRODUCT_TYPE"] == "com.apple.product-type.application"
            || settings["WRAPPER_EXTENSION"]?.lowercased() == "app"
        let platforms = settings["SUPPORTED_PLATFORMS"]?.lowercased() ?? ""
        let platform = settings["PLATFORM_NAME"]?.lowercased() ?? ""
        return isApplication && (platform == "iphoneos" || platforms.contains("iphoneos"))
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

private struct BuildSettingsEntry: Decodable {
    let target: String?
    let buildSettings: [String: String]
}
