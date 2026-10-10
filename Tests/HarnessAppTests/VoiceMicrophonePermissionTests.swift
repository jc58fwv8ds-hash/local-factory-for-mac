import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct VoiceMicrophonePermissionTests {
    @Test func firstUseExplainsTheSystemPromptAndLocalHandling() {
        let guidance = VoiceMicrophoneAuthorization.notDetermined.conversationHelp

        #expect(guidance.contains("初回"))
        #expect(guidance.contains("macOS"))
        #expect(guidance.contains("保存されません"))
    }

    @Test func authorizedUseDoesNotClaimThatEveryStartIsTheFirstUse() {
        let guidance = VoiceMicrophoneAuthorization.authorized.conversationHelp

        #expect(!guidance.contains("初回"))
        #expect(guidance.contains("Mac内"))
        #expect(guidance.contains("保存されません"))
    }

    @Test func deniedAndRestrictedMicrophonesHaveDifferentRecoveryGuidance() {
        let denied = VoiceMicrophoneAuthorization.denied
        let restricted = VoiceMicrophoneAuthorization.restricted

        #expect(denied.failure == .microphoneDenied)
        #expect(restricted.failure == .microphoneRestricted)
        #expect(denied.conversationHelp.contains("システム設定"))
        #expect(restricted.conversationHelp.contains("制限"))
    }

    @Test func deniedProviderFailsWithoutRequestingPermissionAgain() async {
        guard #available(macOS 26.0, *) else { return }
        let authorizer = VoiceMicrophoneAuthorizerFixture(authorization: .denied)
        let provider = AppleSpeechTranscriptionProvider(
            microphoneAuthorizer: authorizer
        )

        do {
            try await start(provider)
            Issue.record("拒否済みのマイクで音声入力が開始されました")
        } catch let error as VoiceTranscriptionError {
            #expect(error == .microphoneDenied)
        } catch {
            Issue.record("想定外のエラーです：\(error.localizedDescription)")
        }
        #expect(authorizer.requestCount == 0)
    }

    @Test func aRejectedFirstRequestReturnsTheResultingPermissionReason() async {
        guard #available(macOS 26.0, *) else { return }
        let authorizer = VoiceMicrophoneAuthorizerFixture(
            authorization: .notDetermined,
            authorizationAfterRequest: .restricted
        )
        let provider = AppleSpeechTranscriptionProvider(
            microphoneAuthorizer: authorizer
        )

        do {
            try await start(provider)
            Issue.record("制限されたマイクで音声入力が開始されました")
        } catch let error as VoiceTranscriptionError {
            #expect(error == .microphoneRestricted)
        } catch {
            Issue.record("想定外のエラーです：\(error.localizedDescription)")
        }
        #expect(authorizer.requestCount == 1)
    }

    @available(macOS 26.0, *)
    private func start(_ provider: AppleSpeechTranscriptionProvider) async throws {
        try await provider.start(
            localeIdentifier: "ja-JP",
            onTranscript: { _ in },
            onActivity: { _ in },
            onStatus: { _ in },
            onFailure: { _ in }
        )
    }
}

@MainActor
private final class VoiceMicrophoneAuthorizerFixture: VoiceMicrophoneAuthorizing {
    private(set) var authorization: VoiceMicrophoneAuthorization
    private(set) var requestCount = 0
    private let authorizationAfterRequest: VoiceMicrophoneAuthorization

    init(
        authorization: VoiceMicrophoneAuthorization,
        authorizationAfterRequest: VoiceMicrophoneAuthorization = .denied
    ) {
        self.authorization = authorization
        self.authorizationAfterRequest = authorizationAfterRequest
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        authorization = authorizationAfterRequest
        return authorization == .authorized
    }
}
