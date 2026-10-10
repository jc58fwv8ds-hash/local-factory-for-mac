import AVFAudio
import AVFoundation
import Foundation
import HarnessCore
import Speech

@available(macOS 26.0, *)
@MainActor
final class AppleSpeechTranscriptionProvider: VoiceTranscriptionProviding {
    let availability = VoiceTranscriptionAvailability.available
    var microphoneAuthorization: VoiceMicrophoneAuthorization {
        microphoneAuthorizer.authorization
    }

    private let microphoneAuthorizer: any VoiceMicrophoneAuthorizing
    private var activeID: UUID?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var speechDetector: SpeechDetector?
    private var audioEngine: AVAudioEngine?
    private var audioInputBridge: AppleSpeechAudioInputBridge?
    private var hasInstalledInputTap = false
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var resultFailure: String?
    private var assembler = VoiceTranscriptAssembler()
    private var onStatus: (@MainActor @Sendable (VoiceTranscriptionStatus) -> Void)?
    private var onFailure: (@MainActor @Sendable (String) -> Void)?
    private var onActivity: (@MainActor @Sendable (VoiceConversationActivity) -> Void)?

    init(
        microphoneAuthorizer: any VoiceMicrophoneAuthorizing = SystemVoiceMicrophoneAuthorizer()
    ) {
        self.microphoneAuthorizer = microphoneAuthorizer
    }

    func start(
        localeIdentifier: String,
        onTranscript: @escaping @MainActor @Sendable (VoiceTranscript) -> Void,
        onActivity: @escaping @MainActor @Sendable (VoiceConversationActivity) -> Void,
        onStatus: @escaping @MainActor @Sendable (VoiceTranscriptionStatus) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        await cancel()
        let id = UUID()
        activeID = id
        self.onStatus = onStatus
        self.onFailure = onFailure
        self.onActivity = onActivity
        assembler = VoiceTranscriptAssembler()
        resultFailure = nil
        do {
            if microphoneAuthorization == .notDetermined {
                onStatus(.requestingMicrophone)
            }
            try await authorizeMicrophone()
            try ensureActive(id)
            onStatus(.preparingLanguageModel)
            let locale = try await supportedLocale(for: localeIdentifier)
            try ensureActive(id)
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let detector = SpeechDetector(
                detectionOptions: .init(sensitivityLevel: .medium),
                reportResults: false
            )
            let modules: [any SpeechModule] = [detector, transcriber]
            try await installAssetsIfNeeded(for: modules, onStatus: onStatus)
            try ensureActive(id)
            try await configureAudio(
                transcriber: transcriber,
                detector: detector,
                locale: locale,
                captureID: id,
                onTranscript: onTranscript
            )
            try ensureActive(id)
            onStatus(.recording)
        } catch {
            await cancel()
            throw error
        }
    }

    func finish() async throws {
        guard activeID != nil else { return }
        onStatus?(.finalizing)
        stopAudioInput()
        inputContinuation?.finish()
        if let analyzer {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultTask?.value
        let failure = resultFailure
        clearSession()
        if let failure {
            throw VoiceTranscriptionError.recognitionFailed(failure)
        }
    }

    func cancel() async {
        activeID = nil
        stopAudioInput()
        inputContinuation?.finish()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        resultTask?.cancel()
        await resultTask?.value
        clearSession()
    }

    private func configureAudio(
        transcriber: SpeechTranscriber,
        detector: SpeechDetector,
        locale: Locale,
        captureID: UUID,
        onTranscript: @escaping @MainActor @Sendable (VoiceTranscript) -> Void
    ) async throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Some audio devices do not expose echo cancellation. The turn policy still
            // filters likely playback echo and the explicit interruption control remains.
        }
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
            throw VoiceTranscriptionError.audioInputUnavailable
        }
        let modules: [any SpeechModule] = [detector, transcriber]
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: naturalFormat
        ), let converter = AppleSpeechAudioConverter(from: naturalFormat, to: analyzerFormat) else {
            throw VoiceTranscriptionError.audioInputUnavailable
        }
        let streamPair = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .lingering
            )
        )
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try ensureActive(captureID)
        self.transcriber = transcriber
        speechDetector = detector
        self.analyzer = analyzer
        audioEngine = engine
        inputContinuation = streamPair.continuation
        observeResults(
            from: transcriber,
            locale: locale,
            captureID: captureID,
            onTranscript: onTranscript
        )
        try await analyzer.start(inputSequence: streamPair.stream)
        try ensureActive(captureID)
        let bridge = AppleSpeechAudioInputBridge(
            converter: converter,
            continuation: streamPair.continuation,
            onFailure: { [weak self] message in self?.onFailure?(message) },
            onActivity: { [weak self] activity in self?.onActivity?(activity) }
        )
        audioInputBridge = bridge
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: naturalFormat,
            block: bridge.makeTapBlock()
        )
        hasInstalledInputTap = true
        engine.prepare()
        try engine.start()
    }

    private func observeResults(
        from transcriber: SpeechTranscriber,
        locale: Locale,
        captureID: UUID,
        onTranscript: @escaping @MainActor @Sendable (VoiceTranscript) -> Void
    ) {
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.activeID == captureID else { return }
                    let text = self.assembler.receive(
                        String(result.text.characters),
                        isFinal: result.isFinal
                    )
                    guard !text.isEmpty else { continue }
                    onTranscript(VoiceTranscript(
                        text: text,
                        localeIdentifier: locale.identifier,
                        stability: result.isFinal ? .finalized : .volatile
                    ))
                }
            } catch is CancellationError {
                // The user released or cancelled the microphone.
            } catch {
                guard let self, self.activeID == captureID else { return }
                self.resultFailure = error.localizedDescription
                self.onFailure?(error.localizedDescription)
            }
        }
    }

    private func authorizeMicrophone() async throws {
        switch microphoneAuthorizer.authorization {
        case .authorized:
            return
        case .notDetermined:
            guard await microphoneAuthorizer.requestAccess() else {
                throw microphoneAuthorizer.authorization.failure
                    ?? VoiceTranscriptionError.microphoneDenied
            }
        case .denied, .restricted, .unavailable:
            throw microphoneAuthorizer.authorization.failure
                ?? VoiceTranscriptionError.microphoneAuthorizationUnavailable
        }
    }

    private func supportedLocale(for identifier: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)
              ) else {
            throw VoiceTranscriptionError.localeUnsupported
        }
        return locale
    }

    private func installAssetsIfNeeded(
        for modules: [any SpeechModule],
        onStatus: @escaping @MainActor @Sendable (VoiceTranscriptionStatus) -> Void
    ) async throws {
        let status = await AssetInventory.status(forModules: modules)
        guard status != .unsupported else {
            throw VoiceTranscriptionError.languageModelUnavailable
        }
        if status != .installed {
            onStatus(.downloadingLanguageModel)
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) else {
                throw VoiceTranscriptionError.languageModelUnavailable
            }
            try await request.downloadAndInstall()
        }
    }

    private func ensureActive(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
    }

    private func stopAudioInput() {
        guard let audioEngine else { return }
        audioEngine.stop()
        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }
    }

    private func clearSession() {
        activeID = nil
        analyzer = nil
        transcriber = nil
        speechDetector = nil
        audioEngine = nil
        audioInputBridge = nil
        hasInstalledInputTap = false
        inputContinuation = nil
        resultTask = nil
        resultFailure = nil
        onStatus = nil
        onFailure = nil
        onActivity = nil
        assembler = VoiceTranscriptAssembler()
    }
}
