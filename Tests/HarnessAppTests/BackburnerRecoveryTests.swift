@testable import HarnessApp
import Foundation
import Testing

struct BackburnerRecoveryTests {
    struct Failure: LocalizedError { let errorDescription: String? }

    @Test func aComputeErrorAfterAGPUTimeoutStartsTheServerAgain() {
        #expect(BackburnerAwareInferenceProvider.leftBroken(Failure(errorDescription: "AIランタイムがエラーを返しました(200): Compute error.")))
        #expect(!BackburnerAwareInferenceProvider.leftBroken(Failure(errorDescription: "接続できませんでした")))
    }
}
