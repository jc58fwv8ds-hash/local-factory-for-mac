import Foundation
import HarnessCore
import Observation

@MainActor
@Observable
final class VoiceEngineStore {
    let catalogEntry = VoiceEngineCatalog.qwen3TTSMLX
    let benchmarkSession: VoiceEngineBenchmarkSession
    private(set) var readiness = VoiceEngineReadiness(
        engineIdentifier: VoiceEngineCatalog.qwen3TTSMLX.id,
        phase: .notInstalled
    )
    private(set) var isRefreshing = false
    private(set) var isInstalling = false
    private(set) var isBenchmarking = false
    private(set) var hasResumableInstallation = false
    private(set) var installationProgress: VoiceEngineInstallationProgress?
    private(set) var preflight: VoiceEngineInstallationPreflight?
    private(set) var operationMessage: String?
    private(set) var errorMessage: String?
    var pendingInstallation = false
    var pendingRemoval = false
    var pendingDiscard = false

    @ObservationIgnored private let adapter: any VoiceEngineAdapting
    @ObservationIgnored private let installer: any VoiceEngineInstalling
    @ObservationIgnored private let capsuleStore: any VoiceCapsulePersisting
    @ObservationIgnored private var installationTask: Task<Void, Never>?

    init(
        adapter: any VoiceEngineAdapting = Qwen3TTSMLXAdapter(),
        installer: any VoiceEngineInstalling = Qwen3TTSMLXInstaller(),
        capsuleStore: any VoiceCapsulePersisting = SystemVoiceCapsuleAssetStore(),
        benchmarkSession: VoiceEngineBenchmarkSession = VoiceEngineBenchmarkSession()
    ) {
        self.adapter = adapter
        self.installer = installer
        self.capsuleStore = capsuleStore
        self.benchmarkSession = benchmarkSession
        benchmarkSession.observeRunning { [weak self] isRunning in
            self?.isBenchmarking = isRunning
        }
    }

    func refresh() async {
        guard canBegin(.refresh, reportsBlocker: false) else { return }
        isRefreshing = true
        async let checkedReadiness = adapter.readiness()
        async let checkedPreflight = installer.preflight()
        async let checkedResume = installer.hasResumableInstallation()
        readiness = await checkedReadiness
        preflight = await checkedPreflight
        hasResumableInstallation = await checkedResume
        isRefreshing = false
    }

    func requestInstallation() {
        errorMessage = nil
        guard canBegin(.installation) else { return }
        guard let preflight else {
            errorMessage = "先に状態を再確認してください。"
            return
        }
        guard preflight.canInstall else {
            errorMessage = preflight.isHardwareSupported
                ? "安全な導入には6GB以上の空き容量が必要です。"
                : "この音声エンジンはApple Silicon搭載Mac専用です。"
            return
        }
        pendingInstallation = true
    }

    func confirmInstallation() {
        pendingInstallation = false
        guard canBegin(.installation) else { return }
        beginInstallation(isResume: false)
    }

    func resumeInstallation() {
        guard hasResumableInstallation else { return }
        guard canBegin(.installation) else { return }
        beginInstallation(isResume: true)
    }

    func stopInstallation() {
        guard isInstalling else { return }
        operationMessage = "音声エンジンの取得を停止しています…"
        installationTask?.cancel()
    }

    func confirmDiscard() {
        pendingDiscard = false
        guard canBegin(.partialDiscard) else { return }
        isInstalling = true
        errorMessage = nil
        installationProgress = VoiceEngineInstallationProgress(
            phase: .deleting,
            status: "途中まで取得したデータを破棄しています"
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await installer.discardPartialInstallation()
                operationMessage = "途中まで取得したデータを破棄しました"
            } catch {
                errorMessage = error.localizedDescription
                operationMessage = nil
            }
            hasResumableInstallation = await installer.hasResumableInstallation()
            isInstalling = false
            installationProgress = nil
        }
    }

    func confirmRemoval() {
        pendingRemoval = false
        guard canBegin(.removal) else { return }
        isInstalling = true
        errorMessage = nil
        installationProgress = VoiceEngineInstallationProgress(
            phase: .deleting,
            status: "ローカル音声エンジンを削除しています"
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await installer.removeInstallation()
                operationMessage = "ローカル音声エンジンを削除しました"
            } catch {
                errorMessage = error.localizedDescription
                operationMessage = nil
            }
            readiness = await adapter.readiness()
            hasResumableInstallation = await installer.hasResumableInstallation()
            isInstalling = false
            installationProgress = nil
        }
    }

    func synthesize(text: String, capsuleID: UUID) async throws -> VoiceSynthesisAudio {
        let input = try await capsuleStore.loadEngineInput(id: capsuleID)
        let audio = try await adapter.synthesize(text: text, input: input)
        readiness = await adapter.readiness()
        return audio
    }

    func startBenchmark(capsuleID: UUID) {
        errorMessage = nil
        guard readiness.canSynthesize else {
            errorMessage = "ローカル音声エンジンの準備が完了していません。"
            return
        }
        guard canBegin(.benchmark) else { return }
        benchmarkSession.start(capsuleID: capsuleID, synthesizer: self)
    }

    func stopBenchmark() {
        benchmarkSession.stop()
    }

    private func beginInstallation(isResume: Bool) {
        guard canBegin(.installation) else { return }
        isInstalling = true
        errorMessage = nil
        operationMessage = isResume
            ? "音声エンジンの取得を再開しています"
            : "音声エンジンを準備しています"
        installationProgress = VoiceEngineInstallationProgress(
            phase: .preparing,
            status: "専用領域を準備しています"
        )
        installationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await installer.install { [weak self] progress in
                    await MainActor.run {
                        guard self?.isInstalling == true else { return }
                        self?.installationProgress = progress
                        self?.operationMessage = progress.status
                    }
                }
                try Task.checkCancellation()
                readiness = await adapter.readiness()
                if readiness.canSynthesize {
                    operationMessage = "ローカル音声エンジンの導入が完了しました"
                } else {
                    errorMessage = "導入内容の最終診断に合格しませんでした。削除してやり直してください。"
                    operationMessage = nil
                }
            } catch is CancellationError {
                readiness = await adapter.readiness()
                operationMessage = readiness.canSynthesize
                    ? "ローカル音声エンジンの導入が完了しました"
                    : "取得を停止しました。続きから再開できます"
            } catch {
                errorMessage = error.localizedDescription
                operationMessage = nil
            }
            hasResumableInstallation = await installer.hasResumableInstallation()
            preflight = await installer.preflight()
            installationTask = nil
            isInstalling = false
            installationProgress = nil
        }
    }

    private var operationState: VoiceEngineOperationState {
        VoiceEngineOperationState(
            isRefreshing: isRefreshing,
            isInstalling: isInstalling,
            isBenchmarking: isBenchmarking
        )
    }

    private func canBegin(
        _ operation: VoiceEngineExclusiveOperation,
        reportsBlocker: Bool = true
    ) -> Bool {
        guard let blocker = VoiceEngineOperationPolicy.blocker(
            for: operation,
            state: operationState
        ) else {
            return true
        }
        if reportsBlocker {
            errorMessage = "\(blockerDescription(blocker))のため、\(operationDescription(operation))は完了後に実行してください。"
        }
        return false
    }

    private func blockerDescription(_ blocker: VoiceEngineOperationBlocker) -> String {
        switch blocker {
        case .refresh: "状態を確認中"
        case .installation: "音声エンジンを準備・削除中"
        case .benchmark: "性能を測定中"
        }
    }

    private func operationDescription(_ operation: VoiceEngineExclusiveOperation) -> String {
        switch operation {
        case .refresh: "状態の再確認"
        case .installation: "音声エンジンの導入"
        case .benchmark: "性能測定"
        case .removal: "音声エンジンの削除"
        case .partialDiscard: "途中データの破棄"
        }
    }
}
