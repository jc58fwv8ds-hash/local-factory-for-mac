import Foundation

public struct StructuredEditInstruction: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case replaceExact = "replace_exact" }
    private enum CodingKeys: String, CodingKey {
        case operation, file
        case expectedOldText = "expected_old_text"
        case newText = "new_text"
        case maxChangedLines = "max_changed_lines"
    }
    public let operation: Operation
    public let file: String
    public let expectedOldText: String
    public let newText: String
    public let maxChangedLines: Int

    public init(operation: Operation, file: String, expectedOldText: String,
                newText: String, maxChangedLines: Int) {
        self.operation = operation
        self.file = file
        self.expectedOldText = expectedOldText
        self.newText = newText
        self.maxChangedLines = maxChangedLines
    }
}

public struct StructuredEditScope: Sendable {
    public let allowedFiles: Set<String>
    public let allowedOperations: Set<StructuredEditInstruction.Operation>
    public let protectedFiles: Set<String>
    public let maxChangedLines: Int

    public init(allowedFiles: Set<String>,
                allowedOperations: Set<StructuredEditInstruction.Operation>,
                protectedFiles: Set<String>, maxChangedLines: Int) {
        self.allowedFiles = allowedFiles
        self.allowedOperations = allowedOperations
        self.protectedFiles = protectedFiles
        self.maxChangedLines = maxChangedLines
    }
}

public enum StructuredEditError: Error, Equatable, Sendable {
    case scopeViolation, invalidInstruction, ambiguousAnchor
}

/// Produces a proposal only. The caller's recorded editor and build gate own writes.
public enum StructuredEditPrimitive {
    public static func proposedContent(_ source: String,
        instruction: StructuredEditInstruction, scope: StructuredEditScope) throws -> String {
        let path = instruction.file
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/").contains(".."),
              scope.allowedFiles.contains(path), !scope.protectedFiles.contains(path),
              scope.allowedOperations.contains(instruction.operation),
              instruction.maxChangedLines == 1, scope.maxChangedLines >= 1 else {
            throw StructuredEditError.scopeViolation
        }
        guard !instruction.expectedOldText.isEmpty,
              !instruction.newText.isEmpty,
              instruction.expectedOldText != instruction.newText,
              !instruction.expectedOldText.contains("\n"),
              !instruction.newText.contains("\n"),
              !instruction.expectedOldText.contains("\r"),
              !instruction.newText.contains("\r") else {
            throw StructuredEditError.invalidInstruction
        }
        let parts = source.components(separatedBy: instruction.expectedOldText)
        guard parts.count == 2 else { throw StructuredEditError.ambiguousAnchor }
        return parts[0] + instruction.newText + parts[1]
    }
}
