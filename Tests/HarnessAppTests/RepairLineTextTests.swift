import Foundation
import HarnessCore
import Testing

struct RepairLineTextTests {
    @Test func theErroringLineGoesWithTheRepair() {
        let source = "final class A {\n    func run() {\n        self.statusText = self.errorMessage\n    }\n}"
        let target = BuildRepairTarget(relativePath: "App/A.swift", diagnostics: [BuildFailureDiagnostic(validationKind: .xcodeBuild,
            relativePath: "App/A.swift", line: 3, column: 9, message: "value of optional type 'String?' must be unwrapped to a value of type 'String'")])
        let text = target.instruction(source: source)
        #expect(text.contains("その行: self.statusText = self.errorMessage"))
        #expect(text.contains("?? 既定値"))
    }
}
