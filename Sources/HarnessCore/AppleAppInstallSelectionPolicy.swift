import Foundation

public enum AppleAppInstallSelectionPolicy {
    public static func installationOrder(
        requested: Set<AppleAppPlatform>,
        app: InstallableAppleApp
    ) -> [AppleAppPlatform] {
        var normalized = requested.filter { app.configuration(for: $0) != nil }
        if normalized.contains(.appleWatch),
           app.configuration(for: .appleWatch)?.watchRelationship == .requiresCompanion,
           app.configuration(for: .iPhone) != nil {
            normalized.insert(.iPhone)
        }
        return AppleAppPlatform.allCases.filter { normalized.contains($0) }
    }
}
