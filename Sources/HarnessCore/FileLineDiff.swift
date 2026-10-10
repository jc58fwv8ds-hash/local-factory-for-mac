import Foundation

enum FileLineDiff {
    static func proposal(
        document: EditableSourceDocument,
        proposedContent: String,
        operation: FileChangeOperation = .update
    ) throws -> FileChangeProposal {
        guard document.content != proposedContent else {
            throw ProjectFileEditError.noChanges
        }

        let originalLines = lines(in: document.content)
        let proposedLines = lines(in: proposedContent)
        let difference = proposedLines.difference(from: originalLines)
        var removalOffsets = Set<Int>()
        var insertions: [Int: String] = [:]

        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removalOffsets.insert(offset)
            case let .insert(offset, element, _):
                insertions[offset] = element
            }
        }

        var diffLines: [FileDiffLine] = []
        var originalIndex = 0
        var proposedIndex = 0

        while originalIndex < originalLines.count || proposedIndex < proposedLines.count {
            if removalOffsets.contains(originalIndex), originalIndex < originalLines.count {
                diffLines.append(
                    FileDiffLine(
                        kind: .removal,
                        oldLineNumber: originalIndex + 1,
                        newLineNumber: nil,
                        text: originalLines[originalIndex]
                    )
                )
                originalIndex += 1
                continue
            }

            if let inserted = insertions[proposedIndex] {
                diffLines.append(
                    FileDiffLine(
                        kind: .addition,
                        oldLineNumber: nil,
                        newLineNumber: proposedIndex + 1,
                        text: inserted
                    )
                )
                proposedIndex += 1
                continue
            }

            if originalIndex < originalLines.count,
               proposedIndex < proposedLines.count,
               originalLines[originalIndex] == proposedLines[proposedIndex] {
                diffLines.append(
                    FileDiffLine(
                        kind: .context,
                        oldLineNumber: originalIndex + 1,
                        newLineNumber: proposedIndex + 1,
                        text: originalLines[originalIndex]
                    )
                )
                originalIndex += 1
                proposedIndex += 1
            } else if originalIndex < originalLines.count {
                diffLines.append(
                    FileDiffLine(
                        kind: .removal,
                        oldLineNumber: originalIndex + 1,
                        newLineNumber: nil,
                        text: originalLines[originalIndex]
                    )
                )
                originalIndex += 1
            } else if proposedIndex < proposedLines.count {
                diffLines.append(
                    FileDiffLine(
                        kind: .addition,
                        oldLineNumber: nil,
                        newLineNumber: proposedIndex + 1,
                        text: proposedLines[proposedIndex]
                    )
                )
                proposedIndex += 1
            }
        }

        let summary = FileChangeSummary(
            addedLineCount: diffLines.count { $0.kind == .addition },
            removedLineCount: diffLines.count { $0.kind == .removal }
        )
        return FileChangeProposal(
            operation: operation,
            relativePath: document.relativePath,
            originalContent: document.content,
            proposedContent: proposedContent,
            diffLines: diffLines,
            summary: summary
        )
    }

    private static func lines(in content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        return content.components(separatedBy: "\n")
    }
}
