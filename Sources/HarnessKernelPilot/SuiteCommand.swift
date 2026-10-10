import Foundation
import HarnessCore
import HarnessExecution

/// Phase B.5 task-suite commands. `--suite-check <candidate> <package> <evidence>`: isolated (OS-sandboxed,
/// network-denied) `swift build` then `swift test` of one package inside `candidate/work/`; prints one JSON line.
enum SuiteCommand {
    enum Failure: Error { case arguments }
    static func run(_ arguments: [String]) async throws {
        switch arguments.dropFirst().first {
        case "--suite-check": try await check(arguments)
        case "--suite-task": try await SuiteTaskRunner.run(arguments)
        default: throw Failure.arguments
        }
    }

    static func check(_ arguments: [String]) async throws {
        guard arguments.count == 5 else { throw Failure.arguments }
        let candidate = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
        let evidence = URL(fileURLWithPath: arguments[4]).standardizedFileURL
        let summary = try await buildAndTest(candidate: candidate, root: root, evidence: evidence)
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    /// Build, then test only when the build passed. Failures are results here, not errors.
    static func buildAndTest(candidate: URL, root: URL, evidence: URL) async throws -> [String: Any] {
        let files = try await ProjectFileEditor().editableFiles(rootPath: root.path)
        let tests = files.map(\.relativePath).filter { $0.hasSuffix(".swift") && $0.split(separator: "/").contains("Tests") }
        let isolated = IsolatedPackageExecution(candidate: candidate, root: root, taskID: root.lastPathComponent,
            protectedPaths: tests.isEmpty ? ["Package.swift"] : tests)
        var summary: [String: Any] = [:]
        for operation in [IsolatedPackageExecution.Operation.build, .test] {
            do {
                let result = try await isolated.execute(operation, evidence: evidence)
                summary[operation.rawValue] = ["exit": Int(result.exitCode), "output": String(result.output.suffix(4_000))]
            } catch {
                summary[operation.rawValue] = ["exit": -1, "error": String(describing: error), "output": latestOutput(operation, evidence)]
                if operation == .build { summary["test"] = ["exit": -1, "error": "notRunBuildFailed", "output": ""] }
                if operation == .build { break }
            }
        }
        return summary
    }

    private static func latestOutput(_ operation: IsolatedPackageExecution.Operation, _ evidence: URL) -> String {
        let receipts = ((try? FileManager.default.contentsOfDirectory(at: evidence, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(operation.rawValue + "-") && !$0.lastPathComponent.contains("adjudicated") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let last = receipts.last, let data = try? Data(contentsOf: last),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return String(((record["output"] as? String) ?? (record["error"] as? String) ?? "").suffix(4_000))
    }
}
