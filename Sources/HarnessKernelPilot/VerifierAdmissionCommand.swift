import Foundation
import HarnessExecution

/// Offline Phase 1 admission: `--verifier-admit <request.json> <claims.json>` prints the fail-closed
/// outcome. Pure replay of recorded claims; never finalizes a task and never calls a model.
enum VerifierAdmissionCommand {
    static func run(_ arguments: [String]) throws {
        if arguments.count == 3 {
            // `--verifier-admit <request.json>` prints the claim prompt and schema for an offline model call.
            let request = try JSONDecoder().decode(RequirementVerification.Request.self,
                                                   from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            let output = ["prompt": try VerifierAdmission.prompt(request), "schema": VerifierAdmission.claimSchema]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
            return
        }
        guard arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        let request = try JSONDecoder().decode(RequirementVerification.Request.self,
                                               from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let claims = try JSONDecoder().decode([VerifierAdmission.Claim].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(VerifierAdmission.admit(claims: claims, request: request)))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
