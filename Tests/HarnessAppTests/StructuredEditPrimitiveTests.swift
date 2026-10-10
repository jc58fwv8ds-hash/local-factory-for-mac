import HarnessCore
import Foundation
import Testing

struct StructuredEditPrimitiveTests {
    private let file = "work/PersonalMemory/WatchMemory/WatchMemoryApp.swift"

    @Test func exactOneLineReplacementProducesOnlyProposal() throws {
        let scope = StructuredEditScope(allowedFiles: [file],
            allowedOperations: [.replaceExact], protectedFiles: ["Tests/Protected.swift"],
            maxChangedLines: 1)
        let instruction = StructuredEditInstruction(operation: .replaceExact,
            file: file, expectedOldText: "Text(\"old\")",
            newText: "Text(\"new\")", maxChangedLines: 1)
        #expect(try StructuredEditPrimitive.proposedContent("a\nText(\"old\")\nb",
            instruction: instruction, scope: scope) == "a\nText(\"new\")\nb")
    }

    @Test func protectedFileAndDuplicateAnchorAreRejected() throws {
        let scope = StructuredEditScope(allowedFiles: [file],
            allowedOperations: [.replaceExact], protectedFiles: [file], maxChangedLines: 1)
        let instruction = StructuredEditInstruction(operation: .replaceExact,
            file: file, expectedOldText: "old", newText: "new", maxChangedLines: 1)
        #expect(throws: StructuredEditError.scopeViolation) {
            try StructuredEditPrimitive.proposedContent("old", instruction: instruction, scope: scope)
        }
        let unprotected = StructuredEditScope(allowedFiles: [file],
            allowedOperations: [.replaceExact], protectedFiles: [], maxChangedLines: 1)
        #expect(throws: StructuredEditError.ambiguousAnchor) {
            try StructuredEditPrimitive.proposedContent("old old", instruction: instruction,
                scope: unprotected)
        }
    }

    @Test func carriageReturnCannotBypassOneLineContract() throws {
        let scope = StructuredEditScope(allowedFiles: [file],
            allowedOperations: [.replaceExact], protectedFiles: [], maxChangedLines: 1)
        let instruction = StructuredEditInstruction(operation: .replaceExact,
            file: file, expectedOldText: "old", newText: "new\rmalicious",
            maxChangedLines: 1)
        #expect(throws: StructuredEditError.invalidInstruction) {
            try StructuredEditPrimitive.proposedContent("old", instruction: instruction, scope: scope)
        }
    }

    @Test func modelProposalUsesStableSnakeCaseSchema() throws {
        let data = Data(#"{"operation":"replace_exact","file":"work/PersonalMemory/WatchMemory/WatchMemoryApp.swift","expected_old_text":"old","new_text":"new","max_changed_lines":1}"#.utf8)
        let decoded = try JSONDecoder().decode(StructuredEditInstruction.self, from: data)
        #expect(decoded.operation == .replaceExact)
        #expect(decoded.maxChangedLines == 1)
        #expect(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("expected_old_text"))
    }
}
