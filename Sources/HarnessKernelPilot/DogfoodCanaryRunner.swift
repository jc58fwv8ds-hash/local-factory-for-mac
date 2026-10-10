import Foundation
import HarnessCore
import HarnessExecution
import HarnessKernel

/// First supervised D1 slice: one deterministic UI edit, a bounded diff and an
/// Xcode Simulator build. No Stable checkout, test file or external model access.
enum DogfoodCanaryRunner {
    private static let target = "work/PersonalMemory/PersonalMemory/PersonalMemoryApp.swift"
    private static let expectedLine = "Text(\"Macへの送信後も録音はこのiPhoneに残ります。\")"
    private static let anchor = "Text(nearbySender.status).font(.caption).foregroundStyle(.secondary)"

    enum Failure: Error {
        case arguments, unsafeRoot, unsafeDiff, buildFailed
    }

    static func run(arguments: [String]) async throws {
        guard arguments.count == 3, arguments[1] == "--canary-personal-memory-deterministic" else {
            throw Failure.arguments
        }
        let route = KernelRoutingPolicy.decide(work: .deterministic, localCompatible: false,
            subscriptionDispatchVerified: false, solAvailable: false, astraAvailable: false)
        guard route.route == .tools else { throw Failure.arguments }
        let root = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        guard root.lastPathComponent == "dogfood-candidate",
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("DOGFOOD_MODE.md").path)
        else { throw Failure.unsafeRoot }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/KernelEdits", isDirectory: true)
        let editor = RecordedProjectFileEditor(directory: support)
        let document = try await editor.load(rootPath: root.path, relativePath: target)
        guard !document.content.contains(expectedLine) else { throw Failure.unsafeDiff }
        let parts = document.content.components(separatedBy: anchor)
        guard parts.count == 2 else { throw Failure.unsafeDiff }
        let content = parts[0] + anchor + "\n                            " + expectedLine + parts[1]
        let proposal = try await editor.makeProposal(document: document, proposedContent: content)
        guard proposal.summary.addedLineCount == 1,
              proposal.summary.removedLineCount == 0,
              proposal.diffLines.filter({ $0.kind == .addition }).allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces) == expectedLine })
        else {
            let detail = "Canary rejected: added=\(proposal.summary.addedLineCount) removed=\(proposal.summary.removedLineCount)"
            try? FileHandle.standardError.write(contentsOf: Data((detail + "\n").utf8))
            throw Failure.unsafeDiff
        }

        try await editor.apply(rootPath: root.path, proposal: proposal)
        do {
            try DogfoodCanaryBuildGate.build(
                project: root.appendingPathComponent("work/PersonalMemory/PersonalMemory.xcodeproj"),
                scheme: "PersonalMemory", sdk: "iphonesimulator",
                destination: "generic/platform=iOS Simulator")
        } catch {
            try await editor.revert(rootPath: root.path, proposal: proposal)
            throw error
        }
        print("DOGFOOD_CANARY: deterministic local edit applied one UI line; iOS Simulator build passed; external verification required")
    }

}
