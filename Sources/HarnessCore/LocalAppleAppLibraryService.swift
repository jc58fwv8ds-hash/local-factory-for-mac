import Foundation

public struct LocalAppleAppLibraryService: AppleAppLibraryProviding, Sendable {
    private let catalog = LocalAppleAppCatalog()
    private let inventory = LocalAppleDeviceInventoryService()
    private let installer: LocalAppleAppInstaller

    public init(preparationProvider: any DevicePreparationProviding = LocalDevicePreparationService()) {
        installer = LocalAppleAppInstaller(preparationProvider: preparationProvider)
    }

    public func discoverApps(in sources: [AppleAppSource]) async throws -> [InstallableAppleApp] {
        try await catalog.discover(in: sources)
    }

    public func listDevices() async throws -> [PhysicalAppleDevice] {
        try await inventory.listDevices()
    }

    public func install(
        _ app: InstallableAppleApp,
        on device: PhysicalAppleDevice,
        onStage: @escaping @Sendable (AppleAppInstallStage) async -> Void
    ) async throws -> AppleAppInstallReport {
        try await installer.install(app, on: device, onStage: onStage)
    }
}
