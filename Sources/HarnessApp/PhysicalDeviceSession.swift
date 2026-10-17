import HarnessCore
import Observation

enum PhysicalDeviceSessionPhase: Equatable {
    case idle
    case loading
    case inspecting
    case running
}

@MainActor
@Observable
final class PhysicalDeviceSession {
    var devices: [PhysicalAppleDevice] = []
    var selectedDeviceID: String?
    var readiness: PhysicalDeviceReadiness?
    var phase: PhysicalDeviceSessionPhase = .idle
    var runStage: PhysicalDeviceRunStage?
    var runReport: PhysicalDeviceRunReport?
    var errorMessage: String?
    var statusMessage: String?

    @ObservationIgnored private let provider: any PhysicalDeviceProviding
    @ObservationIgnored private let rootPath: String
    @ObservationIgnored private var task: Task<Void, Never>?

    init(rootPath: String, provider: any PhysicalDeviceProviding) {
        self.rootPath = rootPath
        self.provider = provider
    }

    var selectedDevice: PhysicalAppleDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var isBusy: Bool { phase != .idle }

    func refresh() {
        perform(phase: .loading) { [weak self] in
            guard let self else { return }
            let refreshed = try await provider.listDevices()
            devices = refreshed
            if !refreshed.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = refreshed.first?.id
            }
            readiness = nil
            guard let device = selectedDevice else { return }
            readiness = try await provider.inspect(rootPath: rootPath, device: device)
            statusMessage = "iPhoneと署名設定を更新しました"
        }
    }

    func selectDevice(_ deviceID: String) {
        guard !isBusy,
              let device = devices.first(where: { $0.id == deviceID }) else { return }
        selectedDeviceID = deviceID
        readiness = nil
        runReport = nil
        perform(phase: .inspecting) { [weak self] in
            guard let self else { return }
            readiness = try await provider.inspect(rootPath: rootPath, device: device)
            statusMessage = "\(device.name)の実行条件を確認しました"
        }
    }

    func runSelected() {
        guard let device = selectedDevice else { return }
        guard readiness?.canRun == true else {
            refresh()
            return
        }
        runReport = nil
        perform(phase: .running) { [weak self] in
            guard let self else { return }
            let report = try await provider.run(
                rootPath: rootPath,
                device: device
            ) { [weak self] stage in
                await self?.setRunStage(stage)
            }
            runReport = report
            if let updated = try? await provider.inspect(rootPath: rootPath, device: device) {
                readiness = updated
            }
            let record = DeviceInstallRecord(appKey: rootPath, appName: report.productName,
                                             deviceIdentifier: report.deviceIdentifier, deviceName: report.deviceName, profile: report.profile)
            if report.profile != nil { DeviceInstallRecordStore.standard.record(record) }
            statusMessage = "\(report.productName)をiPhoneで起動しました" + (record.expiryNote().map { "(\($0))" } ?? "")
        }
    }

    func present(error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = nil
    }

    func stop() {
        task?.cancel()
    }

    private func setRunStage(_ stage: PhysicalDeviceRunStage) {
        runStage = stage
    }

    private func perform(
        phase nextPhase: PhysicalDeviceSessionPhase,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isBusy else { return }
        phase = nextPhase
        runStage = nextPhase == .running ? .preparing : nil
        errorMessage = nil
        statusMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                try Task.checkCancellation()
            } catch is CancellationError {
                errorMessage = "実機操作を停止しました。"
            } catch {
                errorMessage = error.localizedDescription
            }
            phase = .idle
            runStage = nil
            task = nil
        }
    }
}
