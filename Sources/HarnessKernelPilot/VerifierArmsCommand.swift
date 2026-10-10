import Foundation
import HarnessExecution

/// Offline Phase 2 comparison: `--verifier-arms <case.json> <phase1-outcome.json|none>` prints Arm B and Arm C outcomes.
/// Arm A is the frozen Phase 1 binary; its outcome is consumed as data here, never recomputed.
enum VerifierArmsCommand {
    static func run(_ arguments: [String]) throws {
        guard arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        let task = try JSONDecoder().decode(DeterministicVerifier.Case.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let phase1 = arguments[3] == "none" ? nil
            : try JSONDecoder().decode(VerifierAdmission.Outcome.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3]))).items
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let output = ["B": DeterministicVerifier.armB(task), "C": DeterministicVerifier.armC(task, phase1: phase1)]
        FileHandle.standardOutput.write(try encoder.encode(output))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
