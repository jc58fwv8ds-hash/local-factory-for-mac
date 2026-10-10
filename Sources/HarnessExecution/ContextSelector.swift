import Foundation

/// Ephemeral, local-only evidence. Source text is never included in the saved plan.
public struct ContextFileEvidence: Sendable {
    public let path: String
    public let source: String

    public init(path: String, source: String) {
        self.path = path
        self.source = source
    }
}

/// Relevance comes from code vocabulary and references, not a task-specific file allowlist.
public enum ContextSelector {
    /// Readable context and editable scope are different things: `target` files may
    /// be edited, `evidence` files are read-only unless separately promoted.
    public struct Entry: Sendable, Equatable {
        public enum Role: String, Sendable { case target, evidence }
        public let path: String
        public let role: Role
        public let reasons: [String]
        public let relation: String
        public let score: Int
        public var editable: Bool { role == .target }
        public init(path: String, role: Role, reasons: [String], relation: String, score: Int) {
            self.path = path; self.role = role; self.reasons = reasons
            self.relation = relation; self.score = score
        }
    }

    public struct Selection: Sendable {
        /// Whole readable ContextSet (targets first, then evidence).
        public let files: [String]
        public let tests: [String]
        /// Why each selected file is in scope (ranked, explicitly named, or a relationship).
        public var reasons: [String: [String]] = [:]
        public var entries: [Entry] = []
        public var initialCandidates: [RepositorySymbolIndex.Match] = []
        public var needsTargetDiscovery = false
        public var targets: [String] { entries.filter { $0.role == .target }.map(\.path) }
        public var evidence: [String] { entries.filter { $0.role == .evidence }.map(\.path) }
    }

    private struct Signal {
        let triggers: [String]
        let aliases: [String]
    }

    // Small language bridge for general product concepts. No repository paths or
    // concrete source filenames belong here.
    private static let signals: [Signal] = [
        .init(triggers: ["録音", "音声", "recording", "audio"],
              aliases: ["record", "audio", "voice", "memory", "chunk"]),
        .init(triggers: ["受信", "届", "receive", "incoming"],
              aliases: ["receiv", "inbox", "incoming", "arrival"]),
        .init(triggers: ["送信", "転送", "同期", "send", "transfer", "sync"],
              aliases: ["send", "transfer", "sync", "nearby", "transport"]),
        .init(triggers: ["状態", "進捗", "status", "progress"],
              aliases: ["status", "state", "phase", "progress"]),
        .init(triggers: ["表示", "画面", "文言", "ラベル", "display", "screen", "ui"],
              aliases: ["view", "app", "screen", "text", "label", "ui"]),
        .init(triggers: ["再試行", "再送", "retry"],
              aliases: ["retry", "resend", "failure", "error"]),
        .init(triggers: ["予定", "カレンダー", "calendar", "event"],
              aliases: ["calendar", "event", "proposal"])
    ]

    public static func select(objective: String, paths: [String],
                              evidence: [ContextFileEvidence] = []) -> Selection {
        let request = objective.lowercased()
        let presentationOnly = ["中身は変えない", "表示だけ", "文言だけ"]
            .contains { request.contains($0) }
        let active = signals.filter { signal in
            signal.triggers.contains { request.contains($0) }
                && !(presentationOnly && signal.aliases.contains("transfer"))
        }
        let byPath = Dictionary(evidence.map { ($0.path, $0.source.lowercased()) },
                                uniquingKeysWith: { first, _ in first })
        let wantsMac = request.contains("mac")
        let wantsIPhone = request.contains("iphone")
        let wantsWatch = request.contains("watch")
        let wantsPresentation = ["表示", "画面", "文言", "ラベル", "ui", "screen"]
            .contains { request.contains($0) }
        var scores: [String: Int] = [:]
        for path in paths where isSourceOrTest(path) {
            let lower = path.lowercased()
            let name = URL(fileURLWithPath: lower).lastPathComponent
            let source = byPath[path] ?? ""
            var score = 0
            if request.contains(lower) { score += 100 }
            let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            if stem.count >= 5 && request.contains(stem) { score += 60 }
            for signal in active {
                if signal.aliases.contains(where: { name.contains($0) }) { score += 13 }
                else if signal.aliases.contains(where: { lower.contains($0) }) { score += 5 }
                if !source.isEmpty && (signal.triggers.contains(where: { source.contains($0) })
                    || signal.aliases.contains(where: { source.contains($0) })) { score += 9 }
            }
            if wantsPresentation && (name.contains("view") || name.contains("app.")) {
                score += 12
            }
            if wantsPresentation && (source.contains("text(") || source.contains("label(")) {
                score += 8
            }
            if wantsMac {
                if lower.contains("mac") { score += 14 }
                if source.contains("import appkit") || source.contains("nsapp") { score += 18 }
                else if source.contains("mac") { score += 6 }
            }
            if wantsIPhone {
                if lower.contains("iphone") || lower.contains("ios") { score += 14 }
                if source.contains("import uikit") || source.contains("uiapplication") { score += 18 }
            }
            if wantsWatch {
                if lower.contains("watch") { score += 18 }
                if source.contains("import watchkit") || source.contains("wksession") { score += 12 }
            }
            if score > 0 { scores[path] = score }
        }

        // A request for one platform should not scatter into a sibling app
        // merely because both mention the same shared feature in UI copy.
        if wantsMac && !wantsIPhone && !wantsWatch {
            let nativeMac = scores.keys.filter { path in
                let source = byPath[path] ?? ""
                return source.contains("import appkit") || source.contains("nsapp")
            }
            if let best = nativeMac.max(by: { scores[$0, default: 0] == scores[$1, default: 0]
                ? $0 > $1 : scores[$0, default: 0] < scores[$1, default: 0] }) {
                let root = moduleRoot(best)
                for path in Array(scores.keys) where moduleRoot(path) != root {
                    scores[path, default: 0] -= 30
                }
            }
        }

        // A high-scoring file referencing another file's type is dependency
        // evidence. It can raise a related implementation file, but never a
        // completely unrelated path into scope by itself.
        // Deterministic tie-break: Dictionary order is randomised per process.
        let leaders = scores.filter { !isTest($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3)
        for leader in leaders {
            guard let source = byPath[leader.key] else { continue }
            for path in Array(scores.keys) where path != leader.key && !isTest(path) {
                let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
                if stem.count >= 7 && source.contains(stem) { scores[path, default: 0] += 24 }
            }
        }
        let rankedFiles = scores.filter { !isTest($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let strongest = rankedFiles.first?.value ?? 0
        let cutoff = max(18, Int((Double(strongest) * 0.72).rounded(.down)))
        // A source file whose type name the request states as a whole identifier is
        // required context: a related file outranking it must not cut it off.
        let named = rankedFiles.map(\.key).filter { path in
            let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
            return stem.count >= 5 && request.range(of: "(?<![a-z0-9_])" + NSRegularExpression.escapedPattern(for: stem)
                + "(?![a-z0-9_])", options: .regularExpression) != nil
        }
        let ranked = rankedFiles.filter { $0.value >= cutoff }.map(\.key)
        // Stage 1 — Target Selection: files the objective names (file stem or a
        // declared type name), then lexically ranked files. These may be edited.
        let original = Dictionary(evidence.map { ($0.path, $0.source) }, uniquingKeysWith: { first, _ in first })
        let objectiveIdentifiers = ContextRelationships.identifiers(objective)
        let declaresNamedType = paths.filter { isSourceOrTest($0) && !isTest($0) }.sorted().filter { path in
            !ContextRelationships.typeDeclarations(original[path] ?? "").isDisjoint(with: objectiveIdentifiers)
        }
        let clauses = ObjectiveClauses.segment(objective)
        let symbolIndex = RepositorySymbolIndex(sources: original)
        let initialCandidates = symbolIndex.retrieve(clauses: clauses)
        let exactDeclarations = initialCandidates.filter {
            $0.score >= 90 && $0.evidenceType == "exact_identifier_declaration" && !isTest($0.file)
        }.map(\.file)
        // Only deterministic exact-name/declaration evidence is immediately editable.
        // Lexical and subtoken candidates remain READ-ONLY until a requirement plan
        // cites them and Harness validates their relation.
        let seeds = Array(NSOrderedSet(array: named + declaresNamedType + exactDeclarations).array.compactMap { $0 as? String }.prefix(4))
        var reasons: [String: [String]] = [:]
        var entries: [Entry] = []
        for path in seeds {
            var why: [String] = []
            if named.contains(path) { why.append("named in objective") }
            if declaresNamedType.contains(path) {
                let types = ContextRelationships.typeDeclarations(original[path] ?? "").intersection(objectiveIdentifiers).sorted()
                why.append("declares objective type \(types.joined(separator: ", "))")
            }
            why.append("lexical score \(scores[path, default: 0])")
            reasons[path] = why
            entries.append(.init(path: path, role: .target, reasons: why,
                relation: why.first ?? "lexical", score: scores[path, default: 0]))
        }
        let candidateByPath = Dictionary(initialCandidates.map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first })
        let readOnlyCandidates = Array(NSOrderedSet(array: seeds.isEmpty ? ranked : []).array.compactMap { $0 as? String })
            .filter { !seeds.contains($0) && !isTest($0) }.prefix(max(0, 5 - seeds.count))
        for path in readOnlyCandidates {
            let match = candidateByPath[path]
            let why = match.map { ["\($0.evidenceType): \($0.reason)", "matched clause \($0.clauseID)"] }
                ?? ["lexical candidate score \(scores[path, default: 0])"]
            reasons[path] = why
            entries.append(.init(path: path, role: .evidence, reasons: why,
                                 relation: why[0], score: match?.score ?? scores[path, default: 0]))
        }
        // Stage 2 — Evidence Expansion: read-only files needed to change targets correctly.
        let expansion = ContextRelationships.expand(objective: objective, seeds: seeds,
            candidates: paths.filter { isSourceOrTest($0) && !isTest($0) }, sources: original, lexical: scores)
        for item in expansion {
            guard !entries.contains(where: { $0.path == item.path }) else { continue }
            reasons[item.path] = item.reasons
            entries.append(.init(path: item.path, role: .evidence, reasons: item.reasons,
                relation: item.reasons.first ?? "relationship", score: item.score))
        }
        let files = entries.map(\.path)

        let selectedStems = files.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased()
        }
        let selectedModules = Set(files.map(moduleRoot))
        let rankedTests: [(path: String, score: Int)] = scores.filter { isTest($0.key) }.map { path, base in
            let lower = path.lowercased()
            let source = byPath[path] ?? ""
            var references = 0
            for stem in selectedStems where stem.count >= 7 {
                if lower.contains(stem) || source.contains(stem) { references += 1 }
            }
            let moduleScore = selectedModules.contains(moduleRoot(path)) ? 40 : -40
            return (path, base + references * 18 + moduleScore)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return Selection(files: files, tests: rankedTests.prefix(2).map { $0.path }, reasons: reasons,
                         entries: entries, initialCandidates: initialCandidates,
                         needsTargetDiscovery: seeds.isEmpty || (initialCandidates.first?.score ?? 0) < 60)
    }

    private static func isTest(_ path: String) -> Bool {
        path.lowercased().contains("tests/") || path.lowercased().contains("uitests/")
    }

    private static func moduleRoot(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if let source = parts.firstIndex(of: "Sources"), source > 0 {
            return parts[..<source].joined(separator: "/")
        }
        if let tests = parts.firstIndex(where: { $0 == "Tests" || $0.hasSuffix("Tests") }),
           tests > 0 {
            return parts[..<tests].joined(separator: "/")
        }
        return parts.dropLast().joined(separator: "/")
    }

    private static func isSourceOrTest(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".swift", ".go", ".py", ".js", ".ts", ".tsx", ".rs"].contains {
            lower.hasSuffix($0)
        }
    }
}
