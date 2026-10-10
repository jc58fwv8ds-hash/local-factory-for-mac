import Foundation
import HarnessCore
import HarnessExecution
import HarnessKernel

/// D1 Canary 002: exact Watch copy replacement, no arbitrary model edits.
enum DogfoodCanaryWatchRunner {
    private static let target = "work/PersonalMemory/WatchMemory/WatchMemoryApp.swift"
    private static let oldLine = "Text(\"約10分ごとに保存・原本はWatchに保持\").font(.caption2)"
    private static let newLine = "Text(\"約10分ごとに保存。iPhoneに届いても原本はWatchに残ります。\").font(.caption2)"

    enum Failure: Error { case arguments, unsafeRoot, unsafeDiff }

    static func run(arguments: [String]) async throws {
        guard arguments.count == 3, arguments[1] == "--canary-watch-status" else {
            throw Failure.arguments
        }
        let route = KernelRoutingPolicy.decide(work: .deterministic,
            localCompatible: false, subscriptionDispatchVerified: false,
            solAvailable: false, astraAvailable: false)
        guard route.route == .tools else { throw Failure.arguments }
        let root = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        guard root.lastPathComponent == "dogfood-candidate",
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("DOGFOOD_MODE.md").path)
        else { throw Failure.unsafeRoot }

        let scope = StructuredEditScope(allowedFiles: [target],
            allowedOperations: [.replaceExact], protectedFiles: [], maxChangedLines: 1)
        let instruction = StructuredEditInstruction(operation: .replaceExact,
            file: target, expectedOldText: oldLine,
            newText: newLine, maxChangedLines: 1)
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("HarnessCandidate/KernelEdits", isDirectory: true)
        let editor = RecordedProjectFileEditor(directory: support)
        let document = try await editor.load(rootPath: root.path, relativePath: target)
        let content = try StructuredEditPrimitive.proposedContent(document.content,
            instruction: instruction, scope: scope)
        let proposal = try await editor.makeProposal(document: document, proposedContent: content)
        guard proposal.summary.addedLineCount == 1,
              proposal.summary.removedLineCount == 1,
              proposal.diffLines.filter({ $0.kind == .addition }).allSatisfy({
                  $0.text.trimmingCharacters(in: .whitespaces) == newLine
              }),
              proposal.diffLines.filter({ $0.kind == .removal }).allSatisfy({
                  $0.text.trimmingCharacters(in: .whitespaces) == oldLine
              }) else { throw Failure.unsafeDiff }

        try await editor.apply(rootPath: root.path, proposal: proposal)
        do {
            try DogfoodCanaryBuildGate.build(
                project: root.appendingPathComponent("work/PersonalMemory/PersonalMemory.xcodeproj"),
                scheme: "WatchMemory", sdk: "watchsimulator",
                destination: "generic/platform=watchOS Simulator")
        } catch {
            try await editor.revert(rootPath: root.path, proposal: proposal)
            throw error
        }
        print("DOGFOOD_CANARY: structured local Watch edit applied; watchOS Simulator build passed; model coding not attempted; external verification required")
    }
}
