import Foundation
@testable import HarnessCore
@testable import HarnessExecution
import Testing

struct LocalRepairReviewerTests {
    @Test func validReviewUsesOnlyOneSeparateRequest() async throws {
        let provider = ReviewProvider(output: #"{"sourceDigest":"digest","correctness":"pass","maintainability":"pass","explanation":"保存処理を確認しました"}"#)
        let review = try await reviewer(provider).review(input)
        #expect(review.permitsCompletion(for: "digest"))
        let requests = await provider.requests
        #expect(requests.count == 1)
        #expect(requests.first?.messages.map(\.role) == [.system, .user])
        #expect(requests.first?.maximumOutputTokens == 2_048)
        #expect(requests.first?.structuredOutput == .repairReview)
        let schema = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(InferenceJSONSchema(.repairReview))) as? [String: Any])
        #expect(Set(schema["required"] as? [String] ?? []) == Set(["sourceDigest", "correctness", "maintainability", "explanation"]))
        #expect(schema["additionalProperties"] as? Bool == false)
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(properties["correctness"]?["enum"] as? [String] == ["pass", "changesRequired", "insufficientEvidence"])
        let capturedRequest = try #require(requests.first)
        let payload = try #require(JSONSerialization.jsonObject(with: InferencePayloadEncoder.body(for: capturedRequest)) as? [String: Any])
        let transmittedSchema = try #require(payload["format"] as? [String: Any])
        #expect(transmittedSchema["required"] as? [String] == schema["required"] as? [String])
        #expect(transmittedSchema["additionalProperties"] as? Bool == false)
        let options = try #require(payload["options"] as? [String: Any])
        #expect(options["temperature"] as? Double == 0)
    }

    @Test(arguments: ["broken", "oversized", "unknown-verdict", "missing-field"])
    func invalidResponseIsRejectedWithoutRetry(mode: String) async {
        let output: String
        switch mode {
        case "oversized": output = String(repeating: "x", count: 16_385)
        case "unknown-verdict": output = #"{"sourceDigest":"digest","correctness":"maybe","maintainability":"pass","explanation":"理由"}"#
        case "missing-field": output = #"{"sourceDigest":"digest","correctness":"pass","maintainability":"pass"}"#
        default: output = "```json\nnot JSON\n```"
        }
        let provider = ReviewProvider(output: output)
        await #expect(throws: (any Error).self) { try await reviewer(provider).review(input) }
        #expect(await provider.requests.count == 1)
    }

    @Test func timeoutDoesNotRetry() async {
        let provider = ReviewProvider(output: nil)
        let started = ContinuousClock.now
        do {
            _ = try await reviewer(provider, timeout: .milliseconds(30)).review(input)
            Issue.record("A silent stream must time out")
        } catch RepairReviewError.timeout {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await provider.requests.count == 1)
    }

    private var input: RepairReviewInput {
        .init(request: "保存して", source: "let value = 1", sourceDigest: "digest", validationReference: "verified")
    }
    private func reviewer(_ provider: ReviewProvider, timeout: Duration = .seconds(2)) -> LocalRepairReviewer {
        .init(model: "fixture-reviewer", provider: provider, timeout: timeout)
    }
}

private actor ReviewProvider: ModelInferenceProvider {
    let output: String?
    var requests: [InferenceRequest] = []
    init(output: String?) { self.output = output }
    func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            if let output {
                continuation.yield(output)
                continuation.finish()
            }
        }
    }
}
