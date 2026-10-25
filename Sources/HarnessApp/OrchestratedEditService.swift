import Foundation
import HarnessCore
import TaskOrchestrator

/// Orchestrated run (Phase B.4, on by default since 2026-10-07): an AI edit runs through TaskOrchestrator over the whole
/// package on a staged copy; the result reaches the project only through the review/approval step.
/// Off: `defaults write <app> harness.experimental.orchestratedRun -bool NO`. The candidate checkout (its built
/// HarnessKernelPilot is the isolation helper) comes from `harness.experimental.orchestratorCandidatePath`, else from the
/// checkout the App itself runs from; without one the legacy single-call path is used.
struct OrchestratedRunSettings {
    static let enabledKey = "harness.experimental.orchestratedRun"
    static let candidateKey = "harness.experimental.orchestratorCandidatePath"
    static let examinerKey = "harness.experimental.examinerCheck"
    let enabled: Bool
    let candidatePath: String?

    init(defaults: UserDefaults = .standard, executable: URL? = Bundle.main.executableURL) {
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        candidatePath = defaults.string(forKey: Self.candidateKey) ?? executable.flatMap(Self.checkout(containing:))?.path
    }

    /// The package checkout an executable was built in (`<checkout>/.build/<config>/<exe>`), if it has the pilot.
    static func checkout(containing executable: URL) -> URL? {
        var url = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while url.path != "/" {
            if url.lastPathComponent == ".build" {
                let root = url.deletingLastPathComponent()
                let fm = FileManager.default
                return fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
                    && fm.isExecutableFile(atPath: root.appendingPathComponent(".build/debug/HarnessKernelPilot").path) ? root : nil
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// Nil unless the flag is on and the candidate has the built supervisor helper isolation requires.
    var service: (any OrchestratedEditing)? {
        guard enabled, let candidatePath else { return nil }
        let candidate = URL(fileURLWithPath: candidatePath).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: candidate.appendingPathComponent(".build/debug/HarnessKernelPilot").path)
        else { return nil }
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/AppRuns")
        return OrchestratedEditService(candidate: candidate, outputRoot: output)
    }
}

/// One production file the orchestrated run changed or created (`original == nil`).
struct OrchestratedFileChange: Equatable, Sendable {
    let relativePath: String
    let original: String?
    let proposed: String
}

struct OrchestratedEditOutcome: Equatable, Sendable {
    /// Every changed or created production file, the selected file first when it changed.
    let changes: [OrchestratedFileChange]
    let runRecord: URL
    let testsPassedResult: String
    let harnessResult: String
    /// For the checks after the card is shown: the tested copy, the model and the instruction (nil in test doubles).
    var postCheck: PostCheckContext? = nil
}

struct PostCheckContext: Equatable, Sendable {
    let candidate: URL
    let root: URL
    let output: URL
    let model: String
    let objective: String
    let originals: [String: String]
    /// Cases the user answered 違う on in the previous proposal (situation, quantity, setup, expression).
    var seeds: [[String: String]] = []
}

enum OrchestratedEditError: LocalizedError, Equatable {
    case unsupportedRuntime, notSwiftPackage, noTests, targetIsTest, projectTooLarge, noChange
    case failed(phase: String, failureClass: String, record: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRuntime: "オーケストレーター実行は Ollama と Backburner のローカルモデルだけに対応しています。"
        case .notSwiftPackage: "オーケストレーター実行は Swift Package(Package.swift)のプロジェクトだけに対応しています。"
        case .noTests: "テストがないため、変更を検証できません。テストを用意してから実行してください。"
        case .targetIsTest: "テストは合格条件として保護されるため、オーケストレーター実行では編集できません。"
        case .projectTooLarge: "プロジェクトが大きすぎるため、作業用コピーを作れませんでした。"
        case .noChange: "検証を通った変更案がありませんでした。"
        case .failed(let phase, let failureClass, let record):
            "変更案は検証を通りませんでした(\(phase) / \(failureClass))。プロジェクトは変更していません。記録: \(record)"
        }
    }
}

protocol OrchestratedEditing: Sendable {
    func proposeEdit(rootPath: String, relativePath: String, instruction: String,
                     model: ModelSelection) async throws -> OrchestratedEditOutcome
    /// The example check and the examiner on the tested result; returns the updated run record.
    func postChecks(_ context: PostCheckContext) async -> URL?
}

extension OrchestratedEditing {
    func postChecks(_ context: PostCheckContext) async -> URL? { nil }
}

/// Stages the project inside `candidate/work/` (the isolation boundary), runs one orchestrated task over the whole
/// package (package scope: every production source is editable and new files may be created, as in the measured suites),
/// and returns every changed production file when tests passed. Never writes the project; tests stay protected.
struct OrchestratedEditService: OrchestratedEditing {
    static let excluded: Set<String> = [".git", ".build", ".swiftpm", ".harness-execution", "DerivedData"]
    static let maximumFiles = 5_000, maximumBytes = 100 * 1_048_576
    let candidate: URL
    let outputRoot: URL

    func proposeEdit(rootPath: String, relativePath: String, instruction: String,
                     model: ModelSelection) async throws -> OrchestratedEditOutcome {
        guard model.runtime == .ollama || model.runtime == .backburner else { throw OrchestratedEditError.unsupportedRuntime }
        let source = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("Package.swift").path) else {
            throw OrchestratedEditError.notSwiftPackage
        }
        let key = "app-" + UUID().uuidString.prefix(8).lowercased()
        let staging = candidate.appendingPathComponent("work/\(key)")
        let files = try Self.stage(source, into: staging)
        let tests = files.filter { $0.hasSuffix(".swift") && $0.split(separator: "/").contains("Tests") }.sorted()
        guard !tests.isEmpty else { throw OrchestratedEditError.noTests }
        guard !tests.contains(relativePath) else { throw OrchestratedEditError.targetIsTest }
        // Same limits as the measured suites' larger tasks (harness units: 12 edits, 2*maxLines + 12*maxEdits lines).
        let task: [String: Any] = ["objective": instruction, "protectedFiles": tests,
                                   "appendOnly": [String](), "maxEdits": 12, "maxLines": 254]
        try JSONSerialization.data(withJSONObject: task, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("task.json"), options: .atomic)
        let output = outputRoot.appendingPathComponent(key)
        let root = staging.resolvingSymlinksInPath()
        do {
            let run: @Sendable () async throws -> Void = {
                try await TaskOrchestrator.runTask(candidate: candidate, root: root, key: key,
                                                   model: Self.routedModel(model), output: output)
            }
            // The whole task runs under one lease, so a 125B request in the chat waits instead of stopping the 27B mid-task.
            if model.runtime == .backburner {
                try await ModelRuntimes.shared.withLease(ModelRuntimes.defaultBackburner) {
                    try await ModelRuntimes.Backburner().start(model: nil); try await run()
                }
            } else { try await run() }
        } catch {
            throw OrchestratedEditError.failed(phase: "stopped", failureClass: String(describing: error), record: output.path)
        }
        let recordURL = output.appendingPathComponent("result.json")
        let record = (try? JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))) as? [String: Any] ?? [:]
        guard record["phase"] as? String == "testsPassedRequirementVerificationPending",
              let testsPassed = record["testsPassedHarnessResult"] as? String else {
            throw OrchestratedEditError.failed(phase: record["phase"] as? String ?? "unknown",
                failureClass: record["failureClass"] as? String ?? "-", record: recordURL.path)
        }
        let changes = try Self.changes(staged: root, source: source, selected: relativePath)
        guard !changes.isEmpty else { throw OrchestratedEditError.noChange }
        // The examiner and the example check run after the card is shown (postChecks), on this tested copy.
        // Off: `defaults write <app> harness.experimental.examinerCheck -bool NO`.
        let checks = UserDefaults.standard.object(forKey: OrchestratedRunSettings.examinerKey) as? Bool ?? true
        let originals = Dictionary(files.filter { $0.hasPrefix("Sources/") && $0.hasSuffix(".swift") }.compactMap { path in
            (try? String(contentsOf: source.appendingPathComponent(path), encoding: .utf8)).map { (path, $0) }
        }, uniquingKeysWith: { first, _ in first })
        return OrchestratedEditOutcome(changes: changes, runRecord: recordURL, testsPassedResult: testsPassed,
                                       harnessResult: record["harnessResult"] as? String ?? "",
                                       postCheck: checks ? PostCheckContext(candidate: candidate, root: root, output: output,
                                           model: Self.routedModel(model), objective: instruction, originals: originals) : nil)
    }

    func postChecks(_ context: PostCheckContext) async -> URL? {
        await TaskOrchestrator.postChecks(candidate: context.candidate, root: context.root, model: context.model,
                                          objective: context.objective, originals: context.originals, output: context.output,
                                          seeds: context.seeds)
    }

    /// Production Swift files under `Sources/` that differ from the project or are new, the selected file first.
    static func changes(staged: URL, source: URL, selected: String) throws -> [OrchestratedFileChange] {
        let fm = FileManager.default
        let sources = staged.appendingPathComponent("Sources")
        guard let walker = fm.enumerator(at: sources, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var changes: [OrchestratedFileChange] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if excluded.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let relative = "Sources/" + String(url.resolvingSymlinksInPath().path.dropFirst(sources.resolvingSymlinksInPath().path.count + 1))
            let proposed = try String(contentsOf: url, encoding: .utf8)
            let original = try? String(contentsOf: source.appendingPathComponent(relative), encoding: .utf8)
            if proposed != original { changes.append(.init(relativePath: relative, original: original, proposed: proposed)) }
        }
        return changes.sorted { ($0.relativePath == selected ? 0 : 1, $0.relativePath) < ($1.relativePath == selected ? 0 : 1, $1.relativePath) }
    }

    /// Model name for TaskOrchestrator: a Backburner model is routed to the App-managed server by its prefix.
    static func routedModel(_ model: ModelSelection) -> String {
        model.runtime == .backburner ? InferenceRoute.backburnerPrefix + model.identifier : model.identifier
    }

    /// Copies regular files only (no symlinks, no build or VCS state); returns the copied relative paths.
    static func stage(_ source: URL, into staging: URL) throws -> [String] {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: staging.path) else { throw CocoaError(.fileWriteFileExists) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        else { throw OrchestratedEditError.notSwiftPackage }
        var copied: [String] = [], bytes = 0
        for case let url as URL in walker {
            if excluded.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relative = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(source.path.count + 1))
            bytes += values.fileSize ?? 0
            guard copied.count < maximumFiles, bytes <= maximumBytes else { throw OrchestratedEditError.projectTooLarge }
            let target = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: target)
            copied.append(relative)
        }
        return copied
    }
}
