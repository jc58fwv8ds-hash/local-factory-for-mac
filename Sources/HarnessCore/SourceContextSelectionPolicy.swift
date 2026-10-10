import Foundation

public enum SourceContextSelectionStrategy: Equatable, Sendable {
    case allAvailable
    case focused
    case omittedForResponseRevision
}

public struct SourceContextSelection: Equatable, Sendable {
    public let snapshot: SourceContextSnapshot?
    public let strategy: SourceContextSelectionStrategy
    public let originalFileCount: Int
    public let originalCharacterCount: Int

    public var selectedFileCount: Int { snapshot?.files.count ?? 0 }
    public var selectedCharacterCount: Int { snapshot?.totalCharacters ?? 0 }

    public init(
        snapshot: SourceContextSnapshot?,
        strategy: SourceContextSelectionStrategy,
        originalFileCount: Int,
        originalCharacterCount: Int
    ) {
        self.snapshot = snapshot
        self.strategy = strategy
        self.originalFileCount = originalFileCount
        self.originalCharacterCount = originalCharacterCount
    }
}

/// Narrows conversation-only source references without changing collection or file safety rules.
public enum SourceContextSelectionPolicy {
    private static let maximumFocusedFiles = 8
    private static let responseReferences = [
        "今の返答", "この返答", "さっきの返答", "前の返答",
        "今の回答", "この回答", "さっきの回答", "前の回答",
        "今の説明", "この説明", "さっきの説明", "前の説明",
        "今の言い方", "さっきの言い方",
        "previous answer", "last answer", "this response"
    ]
    private static let sourceIntentCues = [
        "コード", "ソース", "実装", "ファイル", "差分", "変更点", "関数", "クラス", "型",
        "ビルド", "テスト", "検証", "xcode", "swift", "画面", "プロジェクト",
        "source", "code", "file", "implementation", "build", "test"
    ]
    private static let noChangeConstraints = [
        "まだファイルは変えないでね", "まだファイルは変えないで", "ファイルは変えないでね",
        "ファイルは変えないで", "ファイルを変えないでね", "ファイルを変えないで",
        "ファイル変更はしないで", "まだ実装しないでね", "まだ実装しないで",
        "コードは変えないでね", "コードは変えないで"
    ]
    private static let genericAnchors: Set<String> = [
        "apple", "harness", "iphone", "macos", "memory", "model", "personal",
        "project", "readme", "source", "sources", "swift", "test", "tests", "view"
    ]

    public static func select(
        _ snapshot: SourceContextSnapshot,
        for project: HarnessProject
    ) -> SourceContextSelection {
        let full = SourceContextSelection(
            snapshot: snapshot,
            strategy: .allAvailable,
            originalFileCount: snapshot.files.count,
            originalCharacterCount: snapshot.totalCharacters
        )
        guard !snapshot.files.isEmpty,
              let instruction = ProjectInstructionContext.userMessages(in: project).last?.content,
              !ContinuationInstruction.matches(instruction) else { return full }

        let anchors = explicitAnchors(in: instruction, projectName: project.name)
        let pathAnchors = anchors.filter { anchor in
            snapshot.files.contains { $0.relativePath.lowercased().contains(anchor) }
        }
        if isResponseOnlyRevision(instruction), pathAnchors.isEmpty {
            return SourceContextSelection(
                snapshot: nil,
                strategy: .omittedForResponseRevision,
                originalFileCount: snapshot.files.count,
                originalCharacterCount: snapshot.totalCharacters
            )
        }

        guard !pathAnchors.isEmpty else { return full }

        let selected = snapshot.files.filter { file in
            let path = file.relativePath.lowercased()
            let content = file.content.lowercased()
            return pathAnchors.contains { path.contains($0) || content.contains($0) }
        }.prefix(maximumFocusedFiles)
        guard !selected.isEmpty, selected.count < snapshot.files.count else { return full }

        let files = Array(selected)
        let narrowed = SourceContextSnapshot(
            files: files,
            totalCharacters: files.reduce(0) { $0 + $1.content.count },
            wasTruncated: true,
            skippedCandidateCount: snapshot.skippedCandidateCount + snapshot.files.count - files.count
        )
        return SourceContextSelection(
            snapshot: narrowed,
            strategy: .focused,
            originalFileCount: snapshot.files.count,
            originalCharacterCount: snapshot.totalCharacters
        )
    }

    private static func isResponseOnlyRevision(_ instruction: String) -> Bool {
        var normalized = instruction.lowercased()
        for phrase in noChangeConstraints {
            normalized = normalized.replacingOccurrences(of: phrase, with: "")
        }
        return (responseReferences.contains(where: normalized.contains)
            || ConversationRephrasePolicy.requestsRephrase(normalized))
            && !sourceIntentCues.contains(where: normalized.contains)
    }

    private static func explicitAnchors(in instruction: String, projectName: String) -> [String] {
        let projectTokens = Set(asciiTokens(in: projectName))
        var anchors = Set<String>()
        for token in asciiTokens(in: instruction) {
            let pieces = [token]
                + token.split(separator: "/").map(String.init)
                + token.split(separator: ".").map(String.init)
            for piece in pieces {
                let candidate = piece.trimmingCharacters(in: CharacterSet(charactersIn: "._-/"))
                guard candidate.count >= 5,
                      !genericAnchors.contains(candidate),
                      !projectTokens.contains(candidate),
                      candidate.contains(where: \Character.isLetter) else { continue }
                anchors.insert(candidate)
            }
        }
        return anchors.sorted()
    }

    private static func asciiTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let allowed = (48...57).contains(value) || (65...90).contains(value)
                || (97...122).contains(value) || [45, 46, 47, 95].contains(value)
            if allowed {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }
}
