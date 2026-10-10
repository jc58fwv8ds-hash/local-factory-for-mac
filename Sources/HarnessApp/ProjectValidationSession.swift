import HarnessCore
import HarnessExecution
import Observation

@MainActor
@Observable
final class ProjectValidationSession {
    let rootPath: String
    var isSupportKnown = false
    var isSupported = false
    var support: ProjectValidationSupport?
    var report: ProjectValidationReport?
    var failureAnalysis: BuildFailureAnalysis?
    var isRunning = false
    var errorMessage: String?
    var recoveryStatus: ValidationRecoveryStatus?
    private var isRecoveryChecked = false
    var canAutomaticallyStart: Bool {
        guard isRecoveryChecked, isSupported, !isRunning else { return false }
        guard let recoveryStatus else { return true }
        return ![ValidationRecoveryStatus.unresolved, .journalUnavailable, .evidenceUnavailable].contains(recoveryStatus)
    }

    @ObservationIgnored private let provider: any ProjectValidating
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryGeneration = 0

    init(rootPath: String, provider: any ProjectValidating) {
        self.rootPath = rootPath
        self.provider = provider
        isRecoveryChecked = !(provider is any ProjectValidationRecovering)
    }

    func detectSupport() async {
        let generation = recoveryGeneration
        support = await provider.support(rootPath: rootPath)
        isSupported = support != nil
        isSupportKnown = true
        guard let recovering = provider as? any ProjectValidationRecovering else { return }
        isRecoveryChecked = false
        do {
            let result = try await recovering.recoverValidation(rootPath: rootPath)
            try Task.checkCancellation()
            guard generation == recoveryGeneration, !isRunning else { return }
            recoveryStatus = result
            isRecoveryChecked = true
        } catch is CancellationError { return }
        catch {
            guard generation == recoveryGeneration, !isRunning else { return }
            recoveryStatus = .evidenceUnavailable
            isRecoveryChecked = true
        }
    }

    /// All automatic entry points share this guard, before publishing a start event.
    func startAutomatically(
        onStart: @MainActor () -> Void,
        onComplete: @escaping @MainActor (ProjectValidationReport) -> Void
    ) {
        guard canAutomaticallyStart else { return }
        onStart()
        start(onComplete: onComplete)
    }

    func start(onComplete: @escaping @MainActor (ProjectValidationReport) -> Void) {
        guard !isRunning else { return }
        recoveryGeneration += 1
        recoveryStatus = nil
        isRunning = true
        report = nil
        failureAnalysis = nil
        errorMessage = nil
        validationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await provider.validate(rootPath: rootPath)
                try Task.checkCancellation()
                report = result
                isRecoveryChecked = true
                failureAnalysis = BuildFailureAnalyzer.analyze(
                    report: result,
                    rootPath: rootPath
                )
                onComplete(result)
            } catch is CancellationError {
                errorMessage = "プロジェクト検証を停止しました。"
                recoveryStatus = .unresolved
            } catch {
                errorMessage = error.localizedDescription
                recoveryStatus = .unresolved
            }
            isRunning = false
            validationTask = nil
        }
    }

    func stop() {
        recoveryGeneration += 1
        validationTask?.cancel()
    }

    func clearResult() {
        guard !isRunning else { return }
        recoveryGeneration += 1
        report = nil
        failureAnalysis = nil
        errorMessage = nil
    }
}
