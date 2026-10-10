import Foundation
import HarnessCore
import HarnessExecution
import HarnessKernel
import TaskOrchestrator

/// D1 local-status-003: supervised local proposal followed by a separately constrained deterministic edit.
enum DogfoodLocalStatusCommand {
    typealias Failure = DogfoodLocalProposalRunner.Failure
    private static let target = "work/PersonalMemory/PersonalMemory/NearbyChunkSender.swift"
    private static let old = "case .awaitingReceipt: \"Macの保存確認待ち\""
    private static let replacement = "case .awaitingReceipt: \"Macに保存できたか確認中\""

    static func run(arguments: [String]) async throws {
        guard arguments.count == 4 else { throw Failure.arguments }
        let root = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        guard root.lastPathComponent == "dogfood-candidate",
              FileManager.default.fileExists(atPath: root.appendingPathComponent("DOGFOOD_MODE.md").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
        else { throw Failure.scope }
        let model = arguments[3]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/Dogfood/local-status-003")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lease = try LocalExecutionLease(file: support.appendingPathComponent("runner.lock"))
        defer { withExtendedLifetime(lease) {} }
        let outcome = support.appendingPathComponent("application.json")
        guard !FileManager.default.fileExists(atPath: outcome.path) else { throw Failure.unfinishedApply }
        let editor = RecordedProjectFileEditor(directory: support.appendingPathComponent("edits"))
        let recorder = RecordedStructuredProposal(directory: support.appendingPathComponent("proposal"), editor: editor)
        let objective = "Macの保存確認待ちの表示を、Macに保存できたか確認中、と分かりやすくして。処理は変えないで。"
        let proposal = try await recorder.prepare(rootPath: root.path, target: target,
            objective: objective, model: model) { _ in
                // Only the bounded line is sent to the local service; it receives no tools.
                let prompt = """
                Return only JSON: operation, file, expected_old_text, new_text, max_changed_lines.
                operation must be replace_exact; file must be \(target); max_changed_lines must be 1.
                Replace exactly this source text: \(old)
                With exactly this source text: \(replacement)
                No other edits. Do not return the full file.
                """
                return try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                    messages: [.init(role: .user, content: prompt)], maximumOutputTokens: 512,
                    structuredOutput: .structuredEdit))
            }
        // The actual write remains the predeclared one-line D1 tool contract.
        guard proposal.diffLines.filter({ $0.kind == .addition }).allSatisfy({
            $0.text.trimmingCharacters(in: .whitespaces) == replacement
        }), proposal.diffLines.filter({ $0.kind == .removal }).allSatisfy({
            $0.text.trimmingCharacters(in: .whitespaces) == old
        }) else {
            try record("taskContractRejected", to: outcome)
            throw Failure.scope
        }
        let route = KernelRoutingPolicy.decide(work: .deterministic, localCompatible: false,
            subscriptionDispatchVerified: false, solAvailable: false, astraAvailable: false)
        guard route.route == .tools else { throw Failure.scope }
        try record("applying", to: outcome)
        try await editor.apply(rootPath: root.path, proposal: proposal)
        try record("awaitingBuild", to: outcome)
        do {
            try DogfoodCanaryBuildGate.build(
                project: root.appendingPathComponent("work/PersonalMemory/PersonalMemory.xcodeproj"),
                scheme: "PersonalMemory", sdk: "iphonesimulator",
                destination: "generic/platform=iOS Simulator")
        } catch {
            try await editor.revert(rootPath: root.path, proposal: proposal)
            try record("buildFailedAndReverted", to: outcome)
            throw error
        }
        try record("buildPassedIndependentVerificationPending", to: outcome)
        print("D1 local-status-003: local structured proposal admitted; one line applied; iOS Simulator build passed. Evidence: \(support.path)")
    }

    private static func record(_ phase: String, to file: URL) throws {
        try JSONEncoder().encode(["phase": phase, "target": target]).write(to: file, options: .atomic)
    }
}
