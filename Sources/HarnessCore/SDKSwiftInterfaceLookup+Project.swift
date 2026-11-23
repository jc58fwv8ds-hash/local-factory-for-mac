import Foundation

/// The Apple Swift types a project already uses, and the other types of their frameworks, for the planner, which sees only
/// file names (2026-11-17: asked for a real fallback listener, the planner did not know 14Translate used SpeechAnalyzer
/// nor that DictationTranscriber exists, wrote 「iOS には標準のオフライン ASR フォールバックがない」 over and over and no plan
/// came back).
extension SDKSwiftInterfaceLookup {
    public func projectReference(rootURL: URL, maximumTypeLines: Int = 40) -> String? {
        let files = TestFailureAnalyzer.swiftFiles(under: rootURL).filter { !$0.contains("Tests/") }.prefix(80)
        let text = files.compactMap { try? String(contentsOf: rootURL.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        let names = Set(Self.candidateNames(text))
        guard !names.isEmpty else { return nil }
        var used: [(framework: String, names: [String], lines: [String])] = []
        for (framework, interface) in loadInterfaces() {
            let lines = Self.typeLines(in: interface)
            let declared = lines.compactMap(Self.typeName)
            let found = declared.filter(names.contains)
            guard !found.isEmpty else { continue }
            used.append((framework, Array(NSOrderedSet(array: found)).compactMap { $0 as? String }, lines))
        }
        guard !used.isEmpty else { return nil }
        // The frameworks the project uses most; SwiftUI and Foundation say little about what can be built.
        let skipped: Set<String> = ["SwiftUI", "SwiftUICore", "CoreFoundation", "Dispatch", "Foundation", "Swift", "Combine", "Observation", "_Concurrency", "UIKit"]
        let chosen = used.filter { !skipped.contains($0.framework) }.sorted { $0.names.count > $1.names.count }.prefix(3)
        guard !chosen.isEmpty else { return nil }
        return "このプロジェクトが使っている Apple の部品(この Mac の Xcode の SDK にある本物。計画ではこれと同じフレームワークにある型を使えます):\n"
            + chosen.map { item in
                "\(item.framework): 使っている型 " + item.names.prefix(8).joined(separator: ", ") + "\n同じフレームワークの型:\n"
                    + Array(NSOrderedSet(array: item.lines)).compactMap { $0 as? String }.prefix(maximumTypeLines).joined(separator: "\n")
            }.joined(separator: "\n")
    }
}
