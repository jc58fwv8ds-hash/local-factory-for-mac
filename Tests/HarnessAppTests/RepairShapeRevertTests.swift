import Foundation
import Testing
@testable import HarnessApp
@testable import HarnessCore

struct RepairShapeRevertTests {
    @Test func shapeErrorsAreTheFilesBraceAndDeclarationErrorsOnly() {
        func plan(_ items: [(String, String)]) -> BuildRepairPlan {
            BuildRepairPlan(targets: items.map { BuildRepairTarget(relativePath: $0.0, diagnostics: [
                BuildFailureDiagnostic(validationKind: .xcodeBuild, relativePath: $0.0, line: 1, column: 1, message: $0.1)]) },
                unresolvedErrorCount: 0)
        }
        let broken = plan([("App/Controller.swift", "Extraneous '}' at top level"), ("App/Screen.swift", "expected '}' in struct")])
        #expect(FileChangeAutopilot.shapeErrors(broken, path: "App/Controller.swift") == ["Extraneous '}' at top level"])
        let meaning = plan([("App/Controller.swift", "value of type 'Pair' has no member 'text'")])
        #expect(FileChangeAutopilot.shapeErrors(meaning, path: "App/Controller.swift").isEmpty)
    }
}
