import Foundation
import Testing
@testable import HarnessApp

struct OriginalFaceTests {
    @Test func theFaceFlagIsLeftOutWithoutAFace() {
        let template: ArraySlice<String> = ["--face", "{face}", "--prompt", "{prompt}"]
        let out = URL(fileURLWithPath: "/tmp/o.png")
        #expect(ImageGenerationService.arguments(template, prompt: "p", output: out) == ["--prompt", "p"])
        #expect(ImageGenerationService.arguments(template, prompt: "p", output: out, face: URL(fileURLWithPath: "/tmp/f.png"))
                == ["--face", "/tmp/f.png", "--prompt", "p"])
    }
}
