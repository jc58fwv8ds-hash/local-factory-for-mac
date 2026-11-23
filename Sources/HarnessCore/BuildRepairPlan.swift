import Foundation

public struct BuildRepairTarget: Identifiable, Equatable, Sendable {
    public var id: String { relativePath }

    public let relativePath: String
    public let diagnostics: [BuildFailureDiagnostic]

    public init(
        relativePath: String,
        diagnostics: [BuildFailureDiagnostic]
    ) {
        self.relativePath = relativePath
        self.diagnostics = diagnostics
    }

    /// The instruction with where each error is: the function, initializer or deinit around its line (2026-11-10: an error
    /// in deinit was taken for one in a closure).
    public func instruction(source: String?, projectRoot: URL? = nil) -> String {
        guard let source else { return instruction }
        let lines = source.components(separatedBy: "\n")
        let places = diagnostics.prefix(4).compactMap { diagnostic -> String? in
            guard let line = diagnostic.line, line >= 1, line <= lines.count else { return nil }
            // The line itself, so the change is made there (2026-11-12: a one-line Optional error came back unchanged twice).
            let code = lines[line - 1].trimmingCharacters(in: .whitespaces)
            let place = Self.enclosing(line: line, in: lines).map { "行\(line) は \($0) の中" } ?? "行\(line)"
            return code.isEmpty ? place : place + "(その行: \(code.prefix(160)))"
        }
        var text = instruction
        // A throwing call in an initializer that cannot throw needs a change of shape, not a 「try」 (2026-11-10).
        let throwsInInit = diagnostics.prefix(4).contains { diagnostic in
            guard let line = diagnostic.line, line >= 1, line <= lines.count,
                  diagnostic.message.contains("can throw") || diagnostic.message.contains("errors thrown from here") else { return false }
            return Self.enclosing(line: line, in: lines)?.hasPrefix("init") == true
        }
        if throwsInInit {
            text += "\n直し方(init の中の投げる呼び出し): try を付けるだけでは直りません。その部品を入れるプロパティを Optional(var x: T?)"
                + "にして init では作らず、使う直前(start などの関数)で let x = try T(…) として作り、失敗したら状態の文言にエラーを出してください。"
        }
        if let projectRoot, let tests = Self.testFileText(for: diagnostics, projectRoot: projectRoot) { text += tests }
        if !places.isEmpty {
            text += "\n場所: " + Array(NSOrderedSet(array: places)).compactMap { $0 as? String }.joined(separator: "、")
        }
        if let projectRoot, let timeout = TypeCheckTimeoutHints.hint(messages: diagnostics.prefix(4).map(\.message), lines: lines,
                                                                   errorLines: diagnostics.prefix(4).compactMap(\.line), projectRoot: projectRoot) {
            text += "\n" + timeout
        }
        // The real names of the project's own types an error says lack a member (2026-11-10).
        if let projectRoot {
            let own = Set(diagnostics.prefix(4).compactMap { ProjectMemberLookup.hint(for: $0.message, projectRoot: projectRoot) }).sorted()
            if !own.isEmpty { text += "\n" + own.joined(separator: "\n") + "\nこの一覧にある名前だけを使い、ない名前を作らないでください。" }
            let values = Set(diagnostics.prefix(4).compactMap { ProjectValueLookup.hint(for: $0.message, projectRoot: projectRoot) }).sorted()
            if !values.isEmpty { text += "\n" + values.joined(separator: "\n") }
        }
        // The project's own functions those lines call, when the error is about the call's arguments (2026-11-16).
        if let projectRoot {
            let erroring = diagnostics.prefix(4).compactMap { $0.line }.filter { $0 >= 1 && $0 <= lines.count }.map { lines[$0 - 1] }
            let declared = ProjectCallLookup.declarations(messages: diagnostics.prefix(4).map(\.message), lines: erroring,
                                                          projectRoot: projectRoot)
            if !declared.isEmpty {
                text += "\n呼んでいる関数の宣言(このプロジェクトのファイルより。引数の名前・順番・型をこれに合わせ、宣言のほうは変えないでください):\n"
                    + declared.map { "- " + $0 }.joined(separator: "\n")
            }
        }
        // The Apple Swift types those lines and errors name, as the SDK declares them (2026-11-17).
        if projectRoot != nil {
            let erroring = diagnostics.prefix(4).compactMap { $0.line }.filter { $0 >= 1 && $0 <= lines.count }.map { lines[$0 - 1] }
            let named = (erroring + diagnostics.prefix(4).map(\.message)).joined(separator: "\n")
            if let reference = SDKSwiftInterfaceLookup.shared.reference(for: named, maximumTypes: 2) { text += "\n" + reference }
        }
        // The C functions those lines call, as their headers declare them (2026-11-10).
        if let projectRoot {
            let erroring = diagnostics.prefix(4).compactMap { $0.line }.filter { $0 >= 1 && $0 <= lines.count }.map { lines[$0 - 1] }
            let prototypes = HeaderPrototypeLookup.prototypes(forLines: erroring, projectRoot: projectRoot)
            if !prototypes.isEmpty {
                text += "\n呼んでいる C の関数の宣言(組み込んだ部品のヘッダーより。引数の数と型をこれに合わせてください):\n"
                    + prototypes.map { "- " + $0 }.joined(separator: "\n")
            }
        }
        return text
    }

    /// The test file a failing test is in, whole: every expectation the file must meet, the ones that pass included
    /// (2026-11-17: shown one failing reading at a time, the repair fixed 「3本」 and broke 「1,000個」, then the reverse).
    static func testFileText(for diagnostics: [BuildFailureDiagnostic], projectRoot: URL, limit: Int = 6_000) -> String? {
        let regex = try! NSRegularExpression(pattern: #"テスト \w+ が失敗\(([\w+.-]+\.swift)\)"#)
        let names = diagnostics.compactMap { diagnostic -> String? in
            let message = diagnostic.message
            return regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message))
                .flatMap { Range($0.range(at: 1), in: message) }.map { String(message[$0]) }
        }
        guard let name = names.first,
              let path = TestFailureAnalyzer.swiftFiles(under: projectRoot).first(where: { ($0 as NSString).lastPathComponent == name }),
              let text = try? String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8) else { return nil }
        let failing = Set(diagnostics.compactMap { diagnostic in
            diagnostic.message.range(of: #"テスト \w+"#, options: .regularExpression).map { String(diagnostic.message[$0].dropFirst(4)) }
        })
        // A result that is the test's own input: nothing happened, so the part that finds or decides let it through
        // (2026-11-17: 「cafe」 came back 「cafe」 for a dozen repairs that rewrote the replacing, not the matching).
        let unchanged = diagnostics.compactMap { diagnostic -> String? in
            guard let got = diagnostic.message.range(of: #"→ "([^"]*)"\)"#, options: .regularExpression).map({ String(diagnostic.message[$0]) }),
                  let value = got.split(separator: "\"").dropFirst().first, text.contains("(\"\(value)\")") || text.contains("(to: \"\(value)\")")
            else { return nil }
            return "「\(value)」は、テストが渡した入力そのままです。処理が何も起きていない(探す・判定する段階で見つかっていない)ので、"
                + "結果を作る部分ではなく、入力を見つける・比べる部分を直してください。"
        }
        // The same expected value checked by another test file, which may already pass: the code it tests already makes it
        // (2026-11-18: the translator's own copy of the number reading failed round after round while the reading file's
        // tests for the same 「さんぼん」 passed).
        let expected = Set(diagnostics.compactMap { diagnostic -> String? in
            diagnostic.message.range(of: #"== "([^"]+)""#, options: .regularExpression)
                .map { String(diagnostic.message[$0].dropFirst(4).dropLast()) }
        })
        var elsewhere: [String] = []
        for path in TestFailureAnalyzer.swiftFiles(under: projectRoot) where path.contains("Tests") && (path as NSString).lastPathComponent != name {
            guard let other = try? String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8) else { continue }
            for line in other.components(separatedBy: "\n") where expected.contains(where: { line.contains("\"\($0)\"") }) {
                elsewhere.append((path as NSString).lastPathComponent + ": " + line.trimmingCharacters(in: .whitespaces).prefix(160))
            }
        }
        let reuse = elsewhere.isEmpty ? "" : "\n同じ期待値をほかのテストも確かめています(そちらのテストが通っていれば、その処理はもうあります。"
            + "同じことを二重に書かず、それを使ってください):\n" + elsewhere.prefix(6).joined(separator: "\n")
        // Where the result first differs from what the test wants, letter by letter (2026-11-18: 「さんせんごひゃくえん」 for
        // 「さんぜんごひゃくえん」 went unfixed all night; the one letter that differs was never named).
        let differences = Array(Set(diagnostics.compactMap { Self.firstDifference(in: $0.message) })).sorted()
        return reuse + (differences.isEmpty ? "" : "\n" + differences.joined(separator: "\n"))
            + (unchanged.isEmpty ? "" : "\n" + Array(Set(unchanged)).sorted().joined(separator: "\n"))
            + "\nこのファイルを確かめるテスト(\(name))の全文です。いま通らないのは " + failing.sorted().joined(separator: "、")
            + " です。ほかのテストも通ったままにして、全部が通るように直してください(テストのほうは変えない):\n"
            + String(text.prefix(limit))
    }

    /// 「期待 X、結果 Y: N 文字目が「a」でなく「b」」 from a test failure that shows both values.
    static func firstDifference(in message: String) -> String? {
        guard let wantRange = message.range(of: #"== "([^"]+)""#, options: .regularExpression),
              let gotRange = message.range(of: #"→ "([^"]*)"\)"#, options: .regularExpression) else { return nil }
        let want = Array(message[wantRange].dropFirst(4).dropLast())
        let got = Array(message[gotRange].dropFirst(3).dropLast(2))
        guard want != got, !got.isEmpty else { return nil }
        let index = zip(want, got).prefix { $0 == $1 }.count
        let wanted = index < want.count ? "「\(want[index])」" : "(終わり)"
        let found = index < got.count ? "「\(got[index])」" : "(終わり)"
        return "期待「\(String(want))」と結果「\(String(got))」は \(index + 1) 文字目から違います: \(wanted)であるべき所が\(found)です。"
            + "その文字を作っている処理(読み方・変換の表や条件)を直してください。"
    }

    /// The nearest declaration above the line that is indented less than it.
    static func enclosing(line: Int, in lines: [String]) -> String? {
        func indent(_ text: String) -> Int { text.prefix { $0 == " " || $0 == "\t" }.count }
        var depth = indent(lines[line - 1])
        var index = line - 2
        while index >= 0 {
            let text = lines[index]
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && indent(text) < depth {
                depth = indent(text)
                if trimmed.hasPrefix("deinit") { return "deinit" }
                if let range = trimmed.range(of: #"\b(init|func \w+)\s*[(<]"#, options: .regularExpression) {
                    return String(trimmed[range].dropLast()).trimmingCharacters(in: .whitespaces) + "(…)"
                }
                if trimmed.range(of: #"\b(class|struct|enum|extension|actor) \w+"#, options: .regularExpression) != nil { return nil }
            }
            index -= 1
        }
        return nil
    }

    /// How every repair instruction begins, so an old one left in the field can be told apart (2026-11-10).
    public static let instructionOpening = "次のビルドエラーを解消してください。"

    public var instruction: String {
        let details = diagnostics.prefix(4).map { diagnostic in
            let location = diagnostic.line.map { "行\($0)" } ?? "位置不明"
            return "- \(location): \(diagnostic.message)"
        }.joined(separator: "\n")
        // The real names of a type the error says lacks a member (2026-11-10).
        let hints = Set(diagnostics.prefix(4).compactMap { SDKMemberLookup.shared.hint(for: $0.message) }).sorted()
        // The real ones with a near name on the framework's other types too (2026-11-17), which every repair is given.
        let near = Set(diagnostics.prefix(4).compactMap {
            SDKSwiftInterfaceLookup.shared.nearMembers(for: $0.message) ?? SDKOptionSetLookup.shared.hint(for: $0.message)
        }).sorted()
        var reference = hints.isEmpty ? "" : "\n" + hints.joined(separator: "\n")
            + (near.isEmpty ? "\nこの一覧にある名前だけを使ってください。" : "\nこの一覧か、次の一覧にある名前だけを使ってください。")
        if !near.isEmpty { reference += "\n" + near.joined(separator: "\n") }
        let advice = BuildErrorAdvice.lines(for: diagnostics.prefix(4).map(\.message))
        if !advice.isEmpty { reference += "\n" + advice.joined(separator: "\n") }
        return """
        次のビルドエラーを解消してください。
        対象ファイル: \(relativePath)
        \(details)\(reference)
        変更範囲をこの1ファイルに限定し、既存の動作を保ってください。
        """
    }
}

public struct BuildRepairPlan: Equatable, Sendable {
    public let targets: [BuildRepairTarget]
    public let unresolvedErrorCount: Int

    public init(
        targets: [BuildRepairTarget],
        unresolvedErrorCount: Int
    ) {
        self.targets = targets
        self.unresolvedErrorCount = unresolvedErrorCount
    }
}

public struct BuildRepairProgress: Equatable, Sendable {
    public let plan: BuildRepairPlan
    public private(set) var currentTargetID: String?
    public private(set) var completedTargetIDs: Set<String>

    public init(
        plan: BuildRepairPlan,
        startingTargetID: String? = nil,
        completedTargetIDs: Set<String> = []
    ) {
        self.plan = plan
        let validStart = plan.targets.contains { $0.id == startingTargetID }
        currentTargetID = validStart ? startingTargetID : plan.targets.first?.id
        self.completedTargetIDs = completedTargetIDs.intersection(
            Set(plan.targets.map(\.id))
        )
    }

    public var currentTarget: BuildRepairTarget? {
        plan.targets.first { $0.id == currentTargetID }
    }

    public var nextTarget: BuildRepairTarget? {
        plan.targets.first {
            !completedTargetIDs.contains($0.id) && $0.id != currentTargetID
        }
    }

    public var completedCount: Int { completedTargetIDs.count }

    @discardableResult
    public mutating func select(relativePath: String) -> BuildRepairTarget? {
        guard let target = plan.targets.first(where: {
            $0.relativePath == relativePath
        }) else { return nil }
        currentTargetID = target.id
        return target
    }

    public mutating func markCompleted(relativePath: String) {
        guard let currentTarget, currentTarget.relativePath == relativePath else { return }
        completedTargetIDs.insert(currentTarget.id)
    }

    public mutating func markCurrentPending() {
        guard let currentTargetID else { return }
        completedTargetIDs.remove(currentTargetID)
    }
}

public enum BuildRepairPlanner {
    public static let maximumTargets = 8

    public static func plan(from analysis: BuildFailureAnalysis) -> BuildRepairPlan? {
        guard !analysis.diagnostics.isEmpty else { return nil }
        var orderedPaths: [String] = []
        var diagnosticsByPath: [String: [BuildFailureDiagnostic]] = [:]

        for diagnostic in analysis.diagnostics {
            if diagnosticsByPath[diagnostic.relativePath] == nil {
                orderedPaths.append(diagnostic.relativePath)
            }
            diagnosticsByPath[diagnostic.relativePath, default: []].append(diagnostic)
        }

        let selectedPaths = orderedPaths.prefix(maximumTargets)
        let targets = selectedPaths.compactMap { path -> BuildRepairTarget? in
            guard let diagnostics = diagnosticsByPath[path], !diagnostics.isEmpty else {
                return nil
            }
            return BuildRepairTarget(relativePath: path, diagnostics: diagnostics)
        }
        let omittedTargetCount = max(0, orderedPaths.count - targets.count)
        return BuildRepairPlan(
            targets: targets,
            unresolvedErrorCount: analysis.unresolvedErrorCount + omittedTargetCount
        )
    }
}
