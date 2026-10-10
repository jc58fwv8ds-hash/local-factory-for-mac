import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

struct CompilerRepairTests {
    let root = URL(fileURLWithPath: "/tmp/pkg")

    @Test func parsesRootRelativeErrorsAndDeduplicates() {
        let output = """
        /tmp/pkg/Sources/A/Limits.swift:12:40: error: no exact matches in call to instance method 'contains'
           |                                        `- error: no exact matches in call to instance method 'contains'
        /tmp/pkg/Sources/A/Limits.swift:12:40: error: no exact matches in call to instance method 'contains'
        /tmp/pkg/Sources/A/Limits.swift:3:1: warning: unused
        /usr/lib/swift/Other.swift:1:1: error: outside
        """
        let diagnostics = CompilerRepair.diagnostics(output: output, root: root)
        #expect(diagnostics.count == 2)
        #expect(diagnostics[0] == .init(path: "Sources/A/Limits.swift", line: 12, column: 40,
            message: "no exact matches in call to instance method 'contains'"))
        #expect(diagnostics[1].path.hasPrefix("<outside>"))
        #expect(CompilerRepair.classify(diagnostics) == .typeMismatch)
    }

    @Test func classifiesCommonFailures() {
        func d(_ m: String) -> [CompilerRepair.Diagnostic] { [.init(path: "a", line: 1, column: 1, message: m)] }
        #expect(CompilerRepair.classify(d("cannot convert value of type 'Int' to expected argument type 'Int64'")) == .typeMismatch)
        #expect(CompilerRepair.classify(d("value of type 'S' has no member 'x'")) == .missingMember)
        #expect(CompilerRepair.classify(d("cannot find 'y' in scope")) == .undefinedSymbol)
        #expect(CompilerRepair.classify(d("expected '}' in struct")) == .syntax)
    }

    @Test func eligibilityNeverLeaksHiddenTestsOrExpandsScope() {
        let permitted: Set<String> = ["Sources/A/Limits.swift"]
        let protected: Set<String> = ["Package.swift", "Tests/ATests/Acceptance.swift"]
        func d(_ path: String) -> CompilerRepair.Diagnostic { .init(path: path, line: 1, column: 1, message: "m") }
        #expect(CompilerRepair.eligibility([], permitted: permitted, protected: protected) == .notCompileFailure)
        #expect(CompilerRepair.eligibility([d("Sources/A/Limits.swift")], permitted: permitted, protected: protected) == .repairable)
        #expect(CompilerRepair.eligibility([d("Tests/ATests/Acceptance.swift")], permitted: permitted, protected: protected) == .hiddenOrProtectedDiagnostic)
        #expect(CompilerRepair.eligibility([d("Tests/ATests/Other.swift")], permitted: permitted, protected: protected) == .hiddenOrProtectedDiagnostic)
        #expect(CompilerRepair.eligibility([d("Sources/A/Limits.swift"), d("Sources/B/User.swift")], permitted: permitted, protected: protected) == .scopeExpansionRequired)
        #expect(CompilerRepair.eligibility([d("<outside>/usr/x.swift")], permitted: permitted, protected: protected) == .scopeExpansionRequired)
    }

    @Test func promptIsMinimalAndBounded() {
        let original = (1...200).map { "line \($0)" }.joined(separator: "\n")
        var lines = original.components(separatedBy: "\n"); lines[99] = "let limit: Int = 5"
        let current = lines.joined(separator: "\n")
        let proposal = FileChangeProposal(relativePath: "Sources/A/Limits.swift", originalContent: original,
            proposedContent: current, diffLines: [.init(kind: .removal, oldLineNumber: 100, newLineNumber: nil, text: "line 100"),
                .init(kind: .addition, oldLineNumber: nil, newLineNumber: 100, text: "let limit: Int = 5"),
                .init(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "UNCHANGED CONTEXT")],
            summary: .init(addedLineCount: 1, removedLineCount: 1))
        let prompt = CompilerRepair.prompt(objective: "Make limits shared", proposals: [proposal],
            current: ["Sources/A/Limits.swift": current, "Sources/B/Unrelated.swift": "SECRET_UNRELATED"],
            diagnostics: [.init(path: "Sources/A/Limits.swift", line: 100, column: 5, message: "type mismatch")],
            maxEdits: 3, maxLines: 20)
        #expect(prompt.contains("Make limits shared"))
        #expect(prompt.contains("+let limit: Int = 5") && prompt.contains("-line 100"))
        #expect(prompt.contains("100: let limit: Int = 5"))
        #expect(prompt.contains("90: line 90") && !prompt.contains("89: line 89"))
        #expect(!prompt.contains("150: line 150"))
        #expect(!prompt.contains("SECRET_UNRELATED") && !prompt.contains("UNCHANGED CONTEXT"))
    }
}
