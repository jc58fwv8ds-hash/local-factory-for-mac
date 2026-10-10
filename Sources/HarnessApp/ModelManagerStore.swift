import AppKit
import Foundation
import HarnessCore
import Observation

@MainActor
@Observable
final class ModelManagerStore {
    var inventory = ModelInventory(models: [], runtimes: [])
    var selectedRuntime: RuntimeKind
    var customIdentifier = ""
    var isRefreshing = false
    var isInstalling = false
    var operationMessage: String?
    var errorMessage: String?
    var pendingInstallation: ModelCatalogEntry?
    var pendingRemoval: InstalledModel?
    var acquisitionCheckpoint: ModelAcquisitionCheckpoint?
    var acquisitionProgress: ModelAcquisitionProgress?
    var hostResources: ModelHostResources

    let catalog = ModelCatalogEntry.recommended

    private let service: LocalModelService
    private let detectedRuntimes: [RuntimeCandidate]
    @ObservationIgnored private var installationTask: Task<Void, Never>?
    @ObservationIgnored private var activeInstallationRequest: ModelAcquisitionRequest?
    @ObservationIgnored private var checkpointDidChange: ((ModelAcquisitionCheckpoint?) -> Void)?

    init(
        runtimes: [RuntimeCandidate],
        acquisitionCheckpoint: ModelAcquisitionCheckpoint? = nil,
        hostResources: ModelHostResources = .current()
    ) {
        self.detectedRuntimes = runtimes
        self.service = LocalModelService(runtimes: runtimes)
        self.acquisitionCheckpoint = ModelAcquisitionCheckpointWorkflow.refreshed(
            acquisitionCheckpoint,
            catalog: ModelCatalogEntry.recommended
        )
        self.hostResources = hostResources

        if runtimes.contains(where: { $0.kind == .lmStudio && $0.isInstalled }) {
            self.selectedRuntime = .lmStudio
        } else if runtimes.contains(where: { $0.kind == .ollama && $0.isInstalled }) {
            self.selectedRuntime = .ollama
        } else {
            self.selectedRuntime = .harness
        }
    }

    var installableRuntimes: [RuntimeKind] {
        detectedRuntimes
            .filter(\.isInstalled)
            .map(\.kind)
            .filter { $0 != .harness }
    }

    var hasInstallableRuntime: Bool { !installableRuntimes.isEmpty }

    var blocksNewInstallation: Bool {
        isInstalling || acquisitionCheckpoint != nil
    }

    var canStopInstallation: Bool {
        isInstalling && activeInstallationRequest != nil
    }

    var canResumeInstallation: Bool {
        guard !isInstalling, let request = acquisitionCheckpoint?.request else {
            return false
        }
        return detectedRuntimes.contains {
            $0.kind == request.runtime && $0.isInstalled
        }
    }

    func configureCheckpointPersistence(
        _ handler: @escaping (ModelAcquisitionCheckpoint?) -> Void
    ) {
        checkpointDidChange = handler
        handler(acquisitionCheckpoint)
    }

    func prepare(preferredRuntime: RuntimeKind?) {
        guard !isInstalling else { return }
        if let checkpointRuntime = acquisitionCheckpoint?.request.runtime {
            selectedRuntime = checkpointRuntime
        } else if let preferredRuntime,
                  installableRuntimes.contains(preferredRuntime) {
            selectedRuntime = preferredRuntime
        }
    }

    func refresh() {
        guard !isRefreshing, !isInstalling else { return }
        isRefreshing = true
        errorMessage = nil
        hostResources = .current()

        Task {
            let updatedInventory = await service.inventory()
            inventory = updatedInventory
            isRefreshing = false
            clearCheckpointIfAlreadyInstalled(in: updatedInventory)
        }
    }

    func requestInstall(_ entry: ModelCatalogEntry) {
        guard acquisitionCheckpoint == nil else {
            errorMessage = "先に中断したモデル取得を再開するか、記録を破棄してください。"
            return
        }
        guard hasInstallableRuntime else {
            errorMessage = "AIランタイムがありません。内蔵ランタイムの追加を待つか、OllamaまたはLM Studioを導入してください。"
            return
        }
        guard validateInstallationCapacity(for: entry) else { return }
        pendingInstallation = entry
    }

    func requestCustomInstall() {
        let cleaned = customIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            errorMessage = "モデルIDまたはHugging Face URLを入力してください。"
            return
        }

        requestInstall(
            ModelCatalogEntry(
                id: "custom-\(cleaned)",
                displayName: cleaned,
                summary: "指定したモデル",
                parameterLabel: "カスタム",
                estimatedSizeGB: 0,
                isRecommended: false,
                ollamaIdentifier: cleaned,
                lmStudioIdentifier: cleaned
            )
        )
    }

    func confirmInstall() {
        guard let entry = pendingInstallation else { return }
        pendingInstallation = nil
        guard let request = ModelAcquisitionRequest(
            entry: entry,
            runtime: selectedRuntime
        ) else {
            errorMessage = "選択したランタイムではこのモデルを取得できません。"
            return
        }
        beginInstallation(request, isResume: false)
    }

    func resumeInstallation() {
        guard let request = acquisitionCheckpoint?.request else { return }
        guard canResumeInstallation else {
            errorMessage = "\(request.runtime.rawValue)が見つかりません。ランタイムを再導入してから再開してください。"
            return
        }
        beginInstallation(request, isResume: true)
    }

    func stopInstallation() {
        guard canStopInstallation else { return }
        operationMessage = "モデル取得を停止しています…"
        installationTask?.cancel()
    }

    func discardAcquisitionCheckpoint() {
        guard !isInstalling else { return }
        ModelAcquisitionCheckpointWorkflow.discarded(in: &acquisitionCheckpoint)
        checkpointDidChange?(acquisitionCheckpoint)
        operationMessage = "モデル取得の中断記録を破棄しました"
        errorMessage = nil
    }

    func requestRemoval(_ model: InstalledModel) {
        pendingRemoval = model
    }

    func confirmRemoval() {
        guard let model = pendingRemoval else { return }
        pendingRemoval = nil
        isInstalling = true
        errorMessage = nil
        operationMessage = "\(model.displayName)を削除しています"

        Task {
            do {
                try await service.remove(model)
                operationMessage = "\(model.displayName)を削除しました"
                inventory = await service.inventory()
            } catch {
                errorMessage = error.localizedDescription
                operationMessage = nil
            }
            isInstalling = false
        }
    }

    func openRuntime(_ runtime: RuntimeKind) {
        let applicationPath: String?
        switch runtime {
        case .harness:
            applicationPath = nil
        case .ollama:
            applicationPath = "/Applications/Ollama.app"
        case .lmStudio:
            applicationPath = "/Applications/LM Studio.app"
        case .backburner:
            applicationPath = nil   // started automatically by BackburnerServer when its model is used
        }

        guard let applicationPath else { return }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: applicationPath),
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.errorMessage = error.localizedDescription
                } else {
                    self?.operationMessage = "\(runtime.rawValue)を起動しました"
                }
            }
        }
    }

    private func beginInstallation(
        _ request: ModelAcquisitionRequest,
        isResume: Bool
    ) {
        guard !isInstalling else { return }
        isInstalling = true
        activeInstallationRequest = request
        acquisitionProgress = nil
        errorMessage = nil
        operationMessage = isResume
            ? "\(request.displayName)の取得を再開しています"
            : "\(request.displayName)をダウンロードしています"
        ModelAcquisitionCheckpointWorkflow.started(
            request,
            in: &acquisitionCheckpoint
        )
        checkpointDidChange?(acquisitionCheckpoint)

        installationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.install(request) { [weak self] progress in
                    await MainActor.run {
                        guard self?.activeInstallationRequest == request else {
                            return
                        }
                        self?.acquisitionProgress = progress
                    }
                }
                try Task.checkCancellation()
                let updatedInventory = await service.inventory()
                guard activeInstallationRequest == request else { return }
                inventory = updatedInventory
                ModelAcquisitionCheckpointWorkflow.completed(
                    request,
                    in: &acquisitionCheckpoint
                )
                checkpointDidChange?(acquisitionCheckpoint)
                operationMessage = "\(request.displayName)をインストールしました"
            } catch is CancellationError {
                guard activeInstallationRequest == request else { return }
                operationMessage = "\(request.displayName)の取得を停止しました。次回は取得済みデータを利用して再開します"
            } catch {
                guard activeInstallationRequest == request else { return }
                errorMessage = error.localizedDescription
                operationMessage = nil
            }
            guard activeInstallationRequest == request else { return }
            activeInstallationRequest = nil
            installationTask = nil
            isInstalling = false
            acquisitionProgress = nil
        }
    }

    private func clearCheckpointIfAlreadyInstalled(
        in inventory: ModelInventory
    ) {
        guard let request = acquisitionCheckpoint?.request,
              inventoryContains(request, in: inventory) else {
            return
        }
        ModelAcquisitionCheckpointWorkflow.completed(
            request,
            in: &acquisitionCheckpoint
        )
        checkpointDidChange?(acquisitionCheckpoint)
        operationMessage = "\(request.displayName)はインストール済みです"
    }

    private func inventoryContains(
        _ request: ModelAcquisitionRequest,
        in inventory: ModelInventory
    ) -> Bool {
        inventory.models.contains { model in
            guard model.runtime == request.runtime else { return false }
            if model.identifier.caseInsensitiveCompare(request.modelIdentifier) == .orderedSame {
                return true
            }
            guard let entry = catalog.first(where: { $0.id == request.catalogEntryID }),
                  !entry.matchingTokens.isEmpty else {
                return false
            }
            let identifier = model.identifier.lowercased()
            return entry.matchingTokens.allSatisfy {
                identifier.contains($0.lowercased())
            }
        }
    }
}
