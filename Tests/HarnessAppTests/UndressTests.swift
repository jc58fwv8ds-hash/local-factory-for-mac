import Testing
import HarnessCore

struct UndressTests {
    @Test func theShirtTheWriterKeptIsTakenOut() {
        let written = "A woman with shoulder-length wavy dark hair, fair skin, and a neutral expression sits against a dark blue background. She is nude except for a white shirt draped over her left shoulder. Her legs are spread wide in an M-shape, with her feet pointing outward. Her clothes are removed."
        let fixed = Undress.apply(written, instruction: "ワイシャツを全て削除。全裸にして")
        #expect(!fixed.lowercased().contains("shirt draped"))
        #expect(!fixed.contains("except"))
        #expect(fixed.contains("dark blue background") && fixed.contains("M-shape"))
        #expect(fixed.hasSuffix("no underwear."))
    }

    @Test func aNamedGarmentGoesAndTheRestStays() {
        let fixed = Undress.apply("She wears a white shirt, blue jeans, sitting on top of the bed.", instruction: "シャツを消して")
        #expect(!fixed.contains("white shirt"))
        #expect(fixed.contains("blue jeans") && fixed.contains("on top of the bed"))
    }

    @Test func undressingInAVideoIsTheActionAndIsKept() {
        let prompt = "She slowly pulls her shirt open and lets it fall."
        #expect(Undress.apply(prompt, instruction: "シャツを脱がせて", isVideo: true) == prompt)
        #expect(Undress.apply(prompt, instruction: "笑顔にして") == prompt)
    }
}
