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
            return Self.enclosing(line: line, in: lines).map { "行\(line) は \($0) の中" }
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
        if !places.isEmpty {
            text += "\n場所: " + Array(NSOrderedSet(array: places)).compactMap { $0 as? String }.joined(separator: "、")
        }
        // The real names of the project's own types an error says lack a member (2026-11-10).
        if let projectRoot {
            let own = Set(diagnostics.prefix(4).compactMap { ProjectMemberLookup.hint(for: $0.message, projectRoot: projectRoot) }).sorted()
            if !own.isEmpty { text += "\n" + own.joined(separator: "\n") + "\nこの一覧にある名前だけを使い、ない名前を作らないでください。" }
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
        var reference = hints.isEmpty ? "" : "\n" + hints.joined(separator: "\n") + "\nこの一覧にある名前だけを使ってください。"
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
