import HarnessCore
import Observation

enum SimulatorSessionPhase: Equatable {
    case idle
    case loading
    case booting
    case capturing
}

@MainActor
@Observable
final class SimulatorSession {
    var devices: [SimulatorDevice] = []
    var selectedDeviceID: String?
    var screenshot: SimulatorScreenshot?
    var phase: SimulatorSessionPhase = .idle
    var errorMessage: String?
    var statusMessage: String?

    @ObservationIgnored private let provider: any SimulatorProviding
    @ObservationIgnored private var task: Task<Void, Never>?

    init(provider: any SimulatorProviding) {
        self.provider = provider
    }

    var selectedDevice: SimulatorDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var isBusy: Bool { phase != .idle }

    func selectDevice(_ deviceID: String) {
        guard devices.contains(where: { $0.id == deviceID }) else { return }
        selectedDeviceID = deviceID
        screenshot = nil
        errorMessage = nil
        statusMessage = nil
    }

    func refresh() {
        perform(phase: .loading) { [weak self] in
            guard let self else { return }
            let devices = try await provider.listDevices()
            self.devices = devices
            if !devices.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = devices.first?.id
            }
            statusMessage = devices.isEmpty ? nil : "利用可能な端末を更新しました"
        }
    }

    func bootSelected() {
        guard let device = selectedDevice else { return }
        screenshot = nil
        perform(phase: .booting) { [weak self] in
            guard let self else { return }
            try await provider.boot(device)
            let refreshedDevices = try await provider.listDevices()
            devices = refreshedDevices
            selectedDeviceID = refreshedDevices.first { $0.id == device.id }?.id
                ?? refreshedDevices.first?.id
            statusMessage = "\(device.name)を起動しました。画面が整うまで数秒かかることがあります"
        }
    }

    func captureSelected() {
        guard let device = selectedDevice else { return }
        perform(phase: .capturing) { [weak self] in
            guard let self else { return }
            screenshot = try await provider.captureScreenshot(of: device)
            statusMessage = "スクリーンショットを一時取得しました"
        }
    }

    func stop() {
        task?.cancel()
    }

    private func perform(
        phase nextPhase: SimulatorSessionPhase,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isBusy else { return }
        phase = nextPhase
        errorMessage = nil
        statusMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                try Task.checkCancellation()
            } catch is CancellationError {
                errorMessage = "Simulator操作を停止しました。"
            } catch {
                errorMessage = error.localizedDescription
            }
            phase = .idle
            task = nil
        }
    }
}
