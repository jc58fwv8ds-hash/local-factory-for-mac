import Foundation
import Testing
import HarnessCore
@testable import TaskOrchestrator

/// Gated fallback candidate with scripted models: the primary keeps producing a wrong change, the secondary a correct one.
extension BatchPipelineReplayTests {
    actor TwoModels {
        let examinerTests: String
        var log: [String] = []
        init(examinerTests: String) { self.examinerTests = examinerTests }
        func respond(_ request: InferenceRequest) throws -> String {
            log.append("\(request.modelIdentifier):\(String(describing: request.structuredOutput))")
            switch request.structuredOutput {
            case .coveragePlan?: return BatchPipelineReplayTests.plan()
            case .structuredEditBatch?:
                return request.modelIdentifier == "secondary" ? BatchPipelineReplayTests.edit("return v", "return min(v, 10)")
                    : BatchPipelineReplayTests.edit("return v", "return min(v, \(log.count % 2 == 0 ? 9 : 8))")
            case .fileContent?:
                return String(decoding: try JSONSerialization.data(withJSONObject: ["content": examinerTests]), as: UTF8.self)
            default: throw CocoaError(.featureUnsupported)
            }
        }
    }

    func runSecond(_ name: String, examinerTests: String) async throws -> (SecondCandidate.Outcome, String) {
        let (root, output, cleanup) = try fixture(name)
        defer { cleanup(); try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent("package-second")) }
        let models = TwoModels(examinerTests: examinerTests)
        let outcome = try await PilotModelSeam.$script.withValue(.init(respond: { try await models.respond($0) })) {
            try await SecondCandidate.run(candidate: candidate, root: root, key: "b3-\(name)", primary: "primary",
                                          secondary: "secondary", examiner: "primary", output: output)
        }
        return (outcome, try String(contentsOf: outcome.root.appendingPathComponent(Self.sourcePath), encoding: .utf8))
    }

    @Test func secondCandidateIsAcceptedOnlyWhenTheExaminerAgrees() async throws {
        let good = "import Testing\n@testable import Meter\n@Test func examinerCaps() { #expect(Meter().level(50) == 10) }\n"
            + "@Test func capsAtTenLevel() { #expect(Meter().level(4) == 4) }\n"     // same name as a package test
        let (accepted, source) = try await runSecond("second-ok", examinerTests: good)
        #expect(accepted.selected == "secondary" && accepted.examinerPassed == 2 && accepted.examinerFailed == 0)
        #expect(source.contains("min(v, 10)"))
        let bad = "import Testing\n@testable import Meter\n@Test func examinerWrongA() { #expect(Meter().level(50) == 50) }\n"
            + "@Test func examinerKeeps() { #expect(Meter().level(4) == 4) }\n"
        let (rejected, _) = try await runSecond("second-gate", examinerTests: bad)
        #expect(rejected.selected == "none" && rejected.examinerFailed == 1)          // 1/2 passed < 0.8 gate
    }
}
