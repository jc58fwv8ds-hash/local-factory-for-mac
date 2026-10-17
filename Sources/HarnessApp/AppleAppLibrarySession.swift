import HarnessCore
import Observation

enum AppleAppLibraryPhase: Equatable {
    case idle
    case loading
    case installing
}

@MainActor
@Observable
final class AppleAppLibrarySession {
    var apps: [InstallableAppleApp] = []
    var devices: [PhysicalAppleDevice] = []
    var selectedAppID: String?
    var selectedPlatforms = Set<AppleAppPlatform>()
    var selectedDeviceIDs: [AppleAppPlatform: String] = [:]
    var phase: AppleAppLibraryPhase = .idle
    var activePlatform: AppleAppPlatform?
    var installStage: AppleAppInstallStage?
    var reports: [AppleAppInstallReport] = []
    var errorMessage: String?
    var statusMessage: String?

    @ObservationIgnored private let provider: any AppleAppLibraryProviding
    @ObservationIgnored private var sources: [AppleAppSource]
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Where installs to a device are recorded with their signature's expiry (tests use their own file).
    @ObservationIgnored var installRecordStore = DeviceInstallRecordStore.standard

    init(sources: [AppleAppSource], provider: any AppleAppLibraryProviding) {
        self.sources = sources
        self.provider = provider
    }

    var selectedApp: InstallableAppleApp? {
        apps.first { $0.id == selectedAppID }
    }

    var isBusy: Bool { phase != .idle }

    var installationOrder: [AppleAppPlatform] {
        guard let selectedApp else { return [] }
        return AppleAppInstallSelectionPolicy.installationOrder(
            requested: selectedPlatforms,
            app: selectedApp
        )
    }

    var canInstall: Bool {
        guard !isBusy, !installationOrder.isEmpty, let selectedApp else { return false }
        return installationOrder.allSatisfy { platform in
            selectedDevice(for: platform) != nil
                && selectedApp.configuration(for: platform)?.signingStyle == .automatic
                && selectedApp.configuration(for: platform)?.hasDevelopmentTeam == true
                && selectedApp.configuration(for: platform)?.hasUsableBundleIdentifier == true
        }
    }

    func updateSources(_ newSources: [AppleAppSource]) {
        sources = newSources
    }

    func refresh() {
        guard !isBusy else { return }
        phase = .loading
        errorMessage = nil
        statusMessage = nil
        reports = []
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let discovered = try await provider.discoverApps(in: sources)
                try Task.checkCancellation()
                let connected = (try? await provider.listDevices()) ?? []
                try Task.checkCancellation()
                apps = discovered
                devices = connected
                normalizeDeviceSelection()
                if !discovered.contains(where: { $0.id == selectedAppID }) {
                    selectedAppID = discovered.first?.id
                }
                selectDefaultPlatforms()
                statusMessage = "アプリと接続端末を更新しました"
            } catch is CancellationError {
                errorMessage = "更新を停止しました。"
            } catch {
                errorMessage = error.localizedDescription
            }
            phase = .idle
            task = nil
        }
    }

    func selectApp(_ id: String) {
        guard !isBusy, apps.contains(where: { $0.id == id }) else { return }
        selectedAppID = id
        reports = []
        errorMessage = nil
        selectDefaultPlatforms()
    }

    func toggle(_ platform: AppleAppPlatform) {
        guard !isBusy, let app = selectedApp,
              app.configuration(for: platform) != nil else { return }
        if selectedPlatforms.contains(platform) {
            selectedPlatforms.remove(platform)
            if platform == .iPhone,
               selectedPlatforms.contains(.appleWatch),
               app.configuration(for: .appleWatch)?.watchRelationship == .requiresCompanion {
                selectedPlatforms.remove(.appleWatch)
            }
        } else {
            selectedPlatforms.insert(platform)
        }
        selectedPlatforms = Set(
            AppleAppInstallSelectionPolicy.installationOrder(
                requested: selectedPlatforms,
                app: app
            )
        )
    }

    func selectDevice(_ id: String, for platform: AppleAppPlatform) {
        guard devices.contains(where: { $0.id == id && $0.platform == platform }) else { return }
        selectedDeviceIDs[platform] = id
    }

    func devices(for platform: AppleAppPlatform) -> [PhysicalAppleDevice] {
        devices.filter { $0.platform == platform }
    }

    func selectedDevice(for platform: AppleAppPlatform) -> PhysicalAppleDevice? {
        let id = selectedDeviceIDs[platform]
        return devices.first { $0.id == id && $0.platform == platform }
    }

    func installSelected() {
        guard canInstall, let app = selectedApp else { return }
        phase = .installing
        reports = []
        errorMessage = nil
        statusMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for platform in installationOrder {
                    guard let device = selectedDevice(for: platform) else {
                        throw AppleAppLibraryError.incompatibleDevice
                    }
                    activePlatform = platform
                    let report = try await provider.install(app, on: device) { [weak self] stage in
                        await self?.setStage(stage, platform: platform)
                    }
                    reports.append(report)
                    if report.profile != nil {
                        installRecordStore.record(DeviceInstallRecord(
                            appKey: app.source.rootPath, appName: report.appName, deviceIdentifier: report.deviceIdentifier,
                            deviceName: report.deviceName, profile: report.profile))
                    }
                }
                statusMessage = completionMessage(app: app)
            } catch is CancellationError {
                errorMessage = "インストールを停止しました。"
            } catch {
                errorMessage = error.localizedDescription
            }
            phase = .idle
            activePlatform = nil
            installStage = nil
            task = nil
        }
    }

    /// 入れ直す (2026-10-12, the user's request): the app of the record installed again on the same device, one press.
    /// Returns why it cannot start (the app or the device is not here), or nil once the install has begun.
    @discardableResult
    func reinstall(_ record: DeviceInstallRecord) -> String? {
        guard !isBusy else { return "ほかのインストールが終わってから押してください。" }
        guard let app = apps.first(where: { $0.source.rootPath == record.appKey }) else {
            return "「\(record.appName)」のプロジェクトが見つかりません。作成アプリの一覧を更新してください。"
        }
        guard let device = devices.first(where: { $0.deviceIdentifier == record.deviceIdentifier }) else {
            return "\(record.deviceName) が見つかりません。ケーブルか同じ Wi-Fi でつないでから、もう一度押してください。"
        }
        selectApp(app.id)
        phase = .installing
        reports = []
        errorMessage = nil
        statusMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                activePlatform = device.platform
                let report = try await provider.install(app, on: device) { [weak self] stage in
                    await self?.setStage(stage, platform: device.platform)
                }
                reports.append(report)
                let renewed = DeviceInstallRecord(appKey: record.appKey, appName: report.appName, deviceIdentifier: report.deviceIdentifier,
                                                  deviceName: report.deviceName, profile: report.profile)
                if report.profile != nil { installRecordStore.record(renewed) }
                statusMessage = "\(app.displayName)を\(device.name)に入れ直しました" + (renewed.expiryNote().map { "(\($0))" } ?? "")
            } catch is CancellationError {
                errorMessage = "インストールを停止しました。"
            } catch {
                errorMessage = error.localizedDescription
            }
            phase = .idle
            activePlatform = nil
            installStage = nil
            task = nil
        }
        return nil
    }

    func stop() {
        task?.cancel()
    }

    func present(error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = nil
    }

    private func selectDefaultPlatforms() {
        guard let app = selectedApp else {
            selectedPlatforms = []
            return
        }
        if app.configuration(for: .iPhone) != nil {
            selectedPlatforms = [.iPhone]
        } else if app.configuration(for: .appleWatch) != nil {
            selectedPlatforms = [.appleWatch]
        } else {
            selectedPlatforms = []
        }
        selectedPlatforms = Set(
            AppleAppInstallSelectionPolicy.installationOrder(
                requested: selectedPlatforms,
                app: app
            )
        )
    }

    private func normalizeDeviceSelection() {
        for platform in AppleAppPlatform.allCases {
            let available = devices(for: platform)
            if !available.contains(where: { $0.id == selectedDeviceIDs[platform] }) {
                selectedDeviceIDs[platform] = available.first?.id
            }
        }
    }

    private func setStage(_ stage: AppleAppInstallStage, platform: AppleAppPlatform) {
        activePlatform = platform
        installStage = stage
    }

    private func completionMessage(app: InstallableAppleApp) -> String {
        let targets = reports.map { $0.platform.displayName }.joined(separator: "と")
        return "\(app.displayName)を\(targets)で起動しました"
    }
}
